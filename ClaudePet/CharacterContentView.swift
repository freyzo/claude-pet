import AppKit

class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A sprite's alpha channel, read once so clicks can be tested without capturing the screen.
struct AlphaMask {
    let width: Int
    let height: Int
    private let alpha: [UInt8]  // row 0 = top of the image

    init?(image: CGImage) {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        alpha = pixels
    }

    /// `point` is in a view of `bounds` showing the image with `.resizeAspect`, optionally mirrored left-right.
    func isOpaque(at point: CGPoint, in bounds: CGRect, mirrored: Bool, threshold: UInt8 = 30) -> Bool {
        guard width > 0, height > 0 else { return false }
        let scale = min(bounds.width / CGFloat(width), bounds.height / CGFloat(height))
        let fitW = CGFloat(width) * scale, fitH = CGFloat(height) * scale
        let originX = bounds.minX + (bounds.width - fitW) / 2
        let originY = bounds.minY + (bounds.height - fitH) / 2
        let x = mirrored ? bounds.minX + bounds.maxX - point.x : point.x
        let px = Int(((x - originX) / scale).rounded(.down))
        let pyFromBottom = Int(((point.y - originY) / scale).rounded(.down))
        guard px >= 0, px < width, pyFromBottom >= 0, pyFromBottom < height else { return false }
        return alpha[(height - 1 - pyFromBottom) * width + px] > threshold
    }
}

class CharacterContentView: NSView {
    weak var character: WalkerCharacter?
    private var trackingArea: NSTrackingArea?
    private var hasPushedHandCursor = false

    /// Avoid opaque backing behind transparent sprite pixels (otherwise you see a dark slab).
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
        window?.invalidateCursorRects(for: self)
    }
    
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
    
    override func mouseEntered(with event: NSEvent) {
        if !hasPushedHandCursor {
            NSCursor.pointingHand.push()
            hasPushedHandCursor = true
        }
        character?.handleMouseEntered()
    }
    
    override func mouseExited(with event: NSEvent) {
        if hasPushedHandCursor {
            NSCursor.pop()
            hasPushedHandCursor = false
        }
        character?.handleMouseExited()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        // Transparent pixels let clicks through to whatever is underneath.
        if let hit = character?.spriteContains(localPoint, in: bounds) {
            return hit ? self : nil
        }

        // Fallback: accept click if within center 60% of the view
        let insetX = bounds.width * 0.2
        let insetY = bounds.height * 0.15
        let hitRect = bounds.insetBy(dx: insetX, dy: insetY)
        return hitRect.contains(localPoint) ? self : nil
    }

    private var isDragging = false
    private var showedContextMenu = false
    private var dragStartLocation: NSPoint = .zero
    private var windowStartOrigin: NSPoint = .zero

    // The menu bar icon can be hidden (notch, crowded bar), so pets offer the same menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        character?.controller?.contextMenuProvider?()
    }

    override func mouseDown(with event: NSEvent) {
        showedContextMenu = false
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            showedContextMenu = true
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        isDragging = false
        dragStartLocation = event.locationInWindow
        windowStartOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard !showedContextMenu, let window = window else { return }
        let currentLocation = event.locationInWindow
        let deltaX = currentLocation.x - dragStartLocation.x
        let deltaY = currentLocation.y - dragStartLocation.y
        
        if !isDragging && (abs(deltaX) > 5 || abs(deltaY) > 5) {
            isDragging = true
            character?.isBeingDragged = true
            character?.keepLegsMovingWhileDragged()
        }
        
        if isDragging {
            let newOrigin = NSPoint(
                x: windowStartOrigin.x + deltaX,
                y: windowStartOrigin.y + deltaY
            )
            window.setFrameOrigin(newOrigin)
            character?.updatePopoverPosition()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if showedContextMenu {
            showedContextMenu = false
        } else if isDragging {
            character?.finishDrag()
        } else {
            character?.handleClick()
        }
        isDragging = false
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { character?.name }
    override func accessibilityHelp() -> String? {
        "Desktop pet. Press to chat with Claude. Drag to move. Right-click for options."
    }

    override func accessibilityPerformPress() -> Bool {
        character?.handleClick()
        return character != nil
    }
}
