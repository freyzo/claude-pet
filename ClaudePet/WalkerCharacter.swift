import AppKit
import QuartzCore

class PopoverDragTitleBarView: NSView {
    var onDragChanged: ((NSPoint) -> Void)?
    private var dragStartScreenPoint: NSPoint = .zero
    private var dragStartWindowOrigin: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        dragStartScreenPoint = NSEvent.mouseLocation
        dragStartWindowOrigin = win.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartScreenPoint.x
        let dy = current.y - dragStartScreenPoint.y
        let newOrigin = NSPoint(x: dragStartWindowOrigin.x + dx, y: dragStartWindowOrigin.y + dy)
        onDragChanged?(newOrigin)
    }
}

class ActionButton: NSButton {
    private var onClick: (() -> Void)?

    convenience init(symbol: String, label: String, onClick: @escaping () -> Void) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        isBordered = false
        self.onClick = onClick
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { onClick?() }
}

class WalkerCharacter {
    var window: NSWindow!
    var spriteLayer: CALayer!
    // [idle, walk1, walk2]
    private var spriteImages: [CGImage] = []
    private var spriteMasks: [AlphaMask] = []
    private let spriteIdleName: String
    private let spriteWalk1Name: String
    private let spriteWalk2Name: String
    private var walkFrameTimer: Timer?
    private var walkFrameInterval: TimeInterval = 0.3
    private var walkAnimStep: Int = 0

    var displayHeight: CGFloat = 300
    private var spriteAspect: CGFloat = 1  // width / height of the idle sprite
    var displayWidth: CGFloat { displayHeight * spriteAspect }

    // Stroll easing timeline in seconds: speed up, cruise, slow down, stop.
    var strollDuration: CFTimeInterval = 10.0
    var accelStart: CFTimeInterval = 3.0
    var fullSpeedStart: CFTimeInterval = 3.75
    var decelStart: CFTimeInterval = 7.5
    var walkStop: CFTimeInterval = 8.25
    var characterColor: NSColor = .gray
    var name = "Stitch"

    // Walk state; positions are 0...1 fractions of the active screen
    var walkStartTime: CFTimeInterval = 0
    var positionX: CGFloat = 0.5
    var positionY: CGFloat = 0.1
    var isWalking = false
    var isPaused = true
    var pauseEndTime: CFTimeInterval = 0
    var goingRight = true
    var walkStartX: CGFloat = 0.0
    var walkEndX: CGFloat = 0.0
    var walkStartY: CGFloat = 0.0
    var walkEndY: CGFloat = 0.0

    // 0 = calm stroller, 1 = full Stitch chaos
    var naughtiness: Double = 0.5
    private enum Antic { case stroll, zoomies, sneak, hop, wiggle, chase, flee }
    private var antic: Antic = .stroll
    private var walkDuration: CFTimeInterval = 10.0
    private var hopCount = 0
    private var hopHeight: CGFloat = 0
    private var wiggleFlips = 0
    private var cursorWasNear = false
    private var fleeCooldownEnd: CFTimeInterval = 0
    private var bubbleIsMischief = false

    // Onboarding
    var isOnboarding = false

    // True only while the user is carrying the pet.
    var isBeingDragged = false

    // Moving windows need every frame; a resting pet only checks timers and the cursor.
    var needsSmoothFrames: Bool { isWalking || isBeingDragged }
    
    // Hover interaction state
    var isHovered = false
    var lastHoverSoundTime: CFTimeInterval = 0
    var hoverReactionShown = false
    private static let hoverPhrases = [
        "hi!", "hey!", "aloha!", "oh hi!", "what's up?",
        "hehe", "boop!", "*waves*", "yo!", "heya!",
        "meega nala kweesta!", "ohana!", ":3"
    ]

    // Popover state
    var isIdleForPopover = false
    var popoverWindow: NSWindow?
    var terminalView: TerminalView?
    var claudeSession: ClaudeSession?
    var clickOutsideMonitor: Any?
    var escapeKeyMonitor: Any?
    weak var controller: ClaudePetController?
    var isClaudeBusy: Bool { claudeSession?.isBusy ?? false }
    var thinkingBubbleWindow: NSWindow?
    var popoverPinnedOrigin: NSPoint?
    private weak var popoverNameLabel: NSTextField?
    private weak var popoverStatusLabel: NSTextField?
    private weak var popoverStatusDot: NSView?
    private weak var newChatButton: NSButton?
    private var shownStatusText: String?

    init(
        spriteIdleName: String,
        spriteWalk1Name: String,
        spriteWalk2Name: String
    ) {
        self.spriteIdleName = spriteIdleName
        self.spriteWalk1Name = spriteWalk1Name
        self.spriteWalk2Name = spriteWalk2Name
    }

    /// `NSImage.cgImage(forProposedRect:...)` often returns an opaque bitmap (alpha lost). Catalog PNGs need this path.
    private static func cgImagePreservingAlpha(named resourceName: String) -> CGImage? {
        guard let image = NSImage(named: resourceName) else { return nil }
        image.isTemplate = false
        for case let bmp as NSBitmapImageRep in image.representations {
            if let cg = bmp.cgImage {
                return cg
            }
        }
        if let tiff = image.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff), let cg = bmp.cgImage {
            return cg
        }
        let bmps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let pw = bmps.map(\.pixelsWide).max() ?? max(1, Int(round(image.size.width)))
        let ph = bmps.map(\.pixelsHigh).max() ?? max(1, Int(round(image.size.height)))
        guard let ctx = CGContext(
            data: nil,
            width: pw,
            height: ph,
            bitsPerComponent: 8,
            bytesPerRow: pw * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: pw, height: ph))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(
            in: NSRect(x: 0, y: 0, width: pw, height: ph),
            from: .zero,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: - Setup

    func setup() {
        let idleImg = Self.cgImagePreservingAlpha(named: spriteIdleName)
        let w1 = Self.cgImagePreservingAlpha(named: spriteWalk1Name)
        let w2 = Self.cgImagePreservingAlpha(named: spriteWalk2Name)

        guard let idleImg, let w1, let w2 else {
            print("Sprite images not found for set: idle=\(spriteIdleName), walk1=\(spriteWalk1Name), walk2=\(spriteWalk2Name)")
            return
        }

        spriteImages = [idleImg, w1, w2]
        spriteMasks = spriteImages.compactMap(AlphaMask.init(image:))
        spriteAspect = CGFloat(idleImg.width) / CGFloat(max(idleImg.height, 1))

        spriteLayer = CALayer()
        spriteLayer.contents = idleImg
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.isOpaque = false
        spriteLayer.backgroundColor = NSColor.clear.cgColor
        // No implicit crossfade between frames; it ghosts the legs.
        spriteLayer.actions = ["contents": NSNull()]
        spriteLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)

        let screen = NSScreen.main!
        let dockTopY = screen.visibleFrame.origin.y
        let bottomPadding = displayHeight * 0.15
        let y = dockTopY - bottomPadding

        let contentRect = CGRect(x: 0, y: y, width: displayWidth, height: displayHeight)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let hostView = CharacterContentView(frame: CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight))
        hostView.character = self
        hostView.wantsLayer = true
        hostView.layer?.isOpaque = false
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        hostView.layer?.addSublayer(spriteLayer)

        window.contentView = hostView
        window.orderFrontRegardless()
    }

    /// Whether the visible sprite frame has a solid pixel at `point`; nil if the masks couldn't be built.
    func spriteContains(_ point: CGPoint, in bounds: CGRect) -> Bool? {
        guard spriteMasks.count == spriteImages.count, spriteMasks.indices.contains(walkAnimStep) else { return nil }
        return spriteMasks[walkAnimStep].isOpaque(at: point, in: bounds, mirrored: !goingRight)
    }

    private func invalidateWalkTimer() {
        walkFrameTimer?.invalidate()
        walkFrameTimer = nil
    }

    private func showIdleSprite() {
        invalidateWalkTimer()
        walkAnimStep = 0
        if !spriteImages.isEmpty {
            spriteLayer?.contents = spriteImages[0]
        }
    }

    private func startWalkSpriteTimer() {
        invalidateWalkTimer()
        guard spriteImages.count >= 3 else { return }
        walkAnimStep = 1
        spriteLayer?.contents = spriteImages[walkAnimStep]
        walkFrameTimer = Timer.scheduledTimer(withTimeInterval: walkFrameInterval, repeats: true) { [weak self] _ in
            self?.advanceWalkSpriteFrame()
        }
        if let t = walkFrameTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func advanceWalkSpriteFrame() {
        guard spriteImages.count >= 3 else { return }
        guard isWalking || isBeingDragged else { return }
        walkAnimStep = (walkAnimStep == 1) ? 2 : 1
        spriteLayer?.contents = spriteImages[walkAnimStep]
    }

    // Legs keep paddling while the pet is carried.
    func keepLegsMovingWhileDragged() {
        guard isBeingDragged, spriteImages.count >= 3 else { return }
        if walkFrameTimer?.isValid == true { return }
        startWalkSpriteTimer()
    }

    func finishDrag() {
        isBeingDragged = false
        if let frame = activeScreen?.frame {
            // Roam on from the drop spot instead of snapping back to the pre-drag position.
            let origin = window.frame.origin
            let maxY = max(frame.height - displayHeight, 0) / frame.height
            positionX = min(max((origin.x - frame.minX) / max(frame.width - displayWidth, 1), 0), 1)
            positionY = min(max((origin.y - frame.minY) / frame.height, 0), maxY)
        }
        // The cursor is still on the pet after a drop; that's not "cursor approached", so no flee.
        cursorWasNear = true
        enterPause()
    }

    /// Stop motion when the character window is hidden from the menu.
    func pauseSpriteForMenuHide() {
        showIdleSprite()
    }

    // MARK: - Click Handling & Popover

    func handleClick() {
        if isOnboarding {
            if isIdleForPopover { closeOnboarding() } else { openOnboardingPopover() }
            return
        }
        if isIdleForPopover {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openOnboardingPopover() {
        showingCompletion = false
        hideBubble()

        isIdleForPopover = true
        isWalking = false
        isPaused = true
        showIdleSprite()

        if popoverWindow == nil {
            createPopoverWindow()
        }

        // Show static welcome message instead of Claude terminal
        terminalView?.inputBar.isHidden = true
        let buddies = (controller?.pets ?? []).filter { $0 !== self }.map(\.name)
        let buddyLine = buddies.isEmpty ? "" : "my buddy \(buddies.joined(separator: " and ")) roams too, and each of us has our own chat.\n\n"
        terminalView?.appendNotice("""
        **aloha! i'm \(name), your naughty lil desktop pet.**

        i roam around your screen. hover over me for a hi, click me anytime to chat with Claude.

        \(buddyLine)[give me a name](claudepet://rename) (or later: menu bar icon → Rename Pet)

        click outside to close, then click me again to start chatting!
        """)

        updatePopoverPosition()
        fadeInPopover()

        // Set up click-outside to dismiss and complete onboarding
        removeEventMonitors()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.closeOnboarding()
        }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closeOnboarding(); return nil }
            return event
        }
    }

    private func closeOnboarding() {
        removeEventMonitors()
        popoverWindow?.orderOut(nil)
        popoverWindow = nil
        terminalView = nil
        isIdleForPopover = false
        isOnboarding = false
        isPaused = true
        pauseEndTime = CACurrentMediaTime() + Double.random(in: 1.0...3.0)
        showIdleSprite()
        controller?.completeOnboarding()
    }

    func openPopover() {
        isIdleForPopover = true
        isWalking = false
        isPaused = true
        showIdleSprite()

        // Always clear any bubble (thinking or completion) when popover opens
        showingCompletion = false
        hideBubble()

        if claudeSession == nil {
            let session = ClaudeSession()
            if let controller {
                session.workingDirectory = controller.workingFolder
                session.allowsEdits = controller.allowsEdits
            }
            claudeSession = session
            wireSession(session)
        }
        // No-op while running; otherwise reconnects (e.g. right after installing or logging in).
        claudeSession?.start()

        if popoverWindow == nil {
            createPopoverWindow()
        }

        if let terminal = terminalView, let session = claudeSession, !session.history.isEmpty {
            terminal.replayHistory(session.history)
        }

        updatePopoverPosition()
        fadeInPopover()
        popoverWindow?.makeKey()

        if let terminal = terminalView {
            popoverWindow?.makeFirstResponder(terminal.inputField)
        }

        // Remove old monitors before adding new ones
        removeEventMonitors()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let popover = self.popoverWindow else { return }
            let popoverFrame = popover.frame
            let charFrame = self.window.frame
            if !popoverFrame.contains(NSEvent.mouseLocation) && !charFrame.contains(NSEvent.mouseLocation) {
                self.closePopover()
            }
        }

        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.closePopover()
                return nil
            }
            return event
        }
    }

    func closePopover() {
        guard isIdleForPopover else { return }

        popoverWindow?.orderOut(nil)
        removeEventMonitors()

        isIdleForPopover = false

        // If still waiting for a response, show thinking bubble immediately
        // If completion came while popover was open, show completion bubble
        if showingCompletion {
            // Reset expiry so user gets the full 3s from now
            completionBubbleExpiry = CACurrentMediaTime() + 3.0
            showBubble(text: currentPhrase, isCompletion: true)
        } else if isClaudeBusy {
            // Force a fresh phrase pick and show immediately
            currentPhrase = ""
            lastPhraseUpdate = 0
            updateThinkingPhrase()
            showBubble(text: currentPhrase, isCompletion: false)
        }

        let delay = Double.random(in: 2.0...5.0)
        pauseEndTime = CACurrentMediaTime() + delay
    }

    private func removeEventMonitors() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }

    private func fadeInPopover() {
        guard let win = popoverWindow else { return }
        win.alphaValue = 0
        win.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            win.animator().alphaValue = 1
        }
    }

    private func refreshPopoverStatus() {
        terminalView?.setBusy(isClaudeBusy)
        // Nothing to clear yet: a live-looking button that does nothing reads as broken.
        let canStartNewChat = !(claudeSession?.history.isEmpty ?? true) || isClaudeBusy
        newChatButton?.isEnabled = canStartNewChat
        newChatButton?.alphaValue = canStartNewChat ? 1 : 0.35
        guard let label = popoverStatusLabel else { return }
        let (text, color) = popoverStatus()
        guard text != shownStatusText else { return }
        shownStatusText = text
        label.stringValue = text
        popoverStatusDot?.layer?.backgroundColor = color.cgColor
    }

    private func popoverStatus() -> (String, NSColor) {
        let t = resolvedTheme
        if isClaudeBusy { return ("thinking…", t.accentColor) }
        switch claudeSession?.status ?? .idle {
        case .offline(let reason): return ("offline · \(reason)", t.textDim)
        case .connecting: return ("connecting…", t.accentColor)
        case .idle, .ready: return (t.titleString, t.successColor)
        }
    }

    func rename(to newName: String) {
        name = newName
        popoverNameLabel?.stringValue = newName
        terminalView?.setPetName(newName)
    }

    func startNewChat() {
        claudeSession?.reset()
        terminalView?.clear()
        terminalView?.setBusy(false)
        refreshPopoverStatus()
    }

    /// Hands new folder / permission settings to a running chat; a session created later reads them itself.
    func applyClaudeSettings(newConversation: Bool, notice: String) {
        guard let session = claudeSession, let controller else { return }
        session.workingDirectory = controller.workingFolder
        session.allowsEdits = controller.allowsEdits
        session.applySettings(newConversation: newConversation, notice: notice)
        terminalView?.setBusy(false)
    }

    private func handleChatAction(_ action: String) {
        switch action {
        case "login":
            if !ClaudeSession.openLoginInTerminal() { terminalView?.appendError("Couldn't open Terminal.") }
        case "install":
            if !ClaudeSession.openInstallInTerminal() { terminalView?.appendError("Couldn't open Terminal.") }
        case "rename":
            controller?.promptRename(self)
        default:
            break
        }
    }

    var resolvedTheme: PopoverTheme {
        PopoverTheme.current.withCharacterColor(characterColor).withCustomFont()
    }

    func createPopoverWindow() {
        let t = resolvedTheme
        let popoverWidth: CGFloat = 400
        let popoverHeight: CGFloat = 340
        let headerHeight: CGFloat = 48

        let win = KeyableWindow(
            contentRect: CGRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 10)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let brightness = t.popoverBg.redComponent * 0.299 + t.popoverBg.greenComponent * 0.587 + t.popoverBg.blueComponent * 0.114
        win.appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.popoverBg.cgColor
        container.layer?.cornerRadius = t.popoverCornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = t.popoverBorderWidth
        container.layer?.borderColor = t.popoverBorder.cgColor
        container.autoresizingMask = [.width, .height]

        let titleBar = PopoverDragTitleBarView(frame: NSRect(x: 0, y: popoverHeight - headerHeight, width: popoverWidth, height: headerHeight))
        titleBar.autoresizingMask = [.width, .minYMargin]
        titleBar.onDragChanged = { [weak self, weak win] newOrigin in
            guard let self = self, let win = win else { return }
            guard let screen = NSScreen.main else {
                win.setFrameOrigin(newOrigin)
                self.popoverPinnedOrigin = newOrigin
                return
            }
            let maxX = screen.frame.maxX - win.frame.width - 4
            let maxY = screen.frame.maxY - win.frame.height - 4
            let clamped = NSPoint(
                x: max(screen.frame.minX + 4, min(newOrigin.x, maxX)),
                y: max(screen.frame.minY + 4, min(newOrigin.y, maxY))
            )
            win.setFrameOrigin(clamped)
            self.popoverPinnedOrigin = clamped
        }
        container.addSubview(titleBar)

        let avatar = NSView(frame: NSRect(x: 14, y: (headerHeight - 32) / 2, width: 32, height: 32))
        avatar.wantsLayer = true
        avatar.layer?.backgroundColor = t.titleBarBg.cgColor
        avatar.layer?.cornerRadius = 16
        avatar.layer?.masksToBounds = true
        avatar.layer?.contents = spriteImages.first
        avatar.layer?.contentsGravity = .resizeAspect
        titleBar.addSubview(avatar)

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont(descriptor: t.titleFont.fontDescriptor, size: 13) ?? t.titleFont
        nameLabel.textColor = t.titleText
        nameLabel.frame = NSRect(x: 56, y: headerHeight / 2, width: 240, height: 17)
        titleBar.addSubview(nameLabel)

        let statusDot = NSView(frame: NSRect(x: 57, y: headerHeight / 2 - 11, width: 7, height: 7))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        titleBar.addSubview(statusDot)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        statusLabel.textColor = t.textDim
        statusLabel.frame = NSRect(x: 69, y: headerHeight / 2 - 15, width: 220, height: 14)
        titleBar.addSubview(statusLabel)

        let closeButton = ActionButton(symbol: "xmark", label: "Close") { [weak self] in
            guard let self else { return }
            if self.isOnboarding { self.closeOnboarding() } else { self.closePopover() }
        }
        closeButton.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        closeButton.contentTintColor = t.textDim
        closeButton.frame = NSRect(x: popoverWidth - 36, y: (headerHeight - 22) / 2, width: 22, height: 22)
        closeButton.autoresizingMask = [.minXMargin]
        titleBar.addSubview(closeButton)

        let newChatButton = ActionButton(symbol: "plus.bubble", label: "New Chat") { [weak self] in
            self?.startNewChat()
        }
        newChatButton.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        newChatButton.contentTintColor = t.textDim
        newChatButton.toolTip = "New chat (clears this conversation)"
        newChatButton.frame = NSRect(x: popoverWidth - 64, y: (headerHeight - 22) / 2, width: 22, height: 22)
        newChatButton.autoresizingMask = [.minXMargin]
        newChatButton.isHidden = isOnboarding
        titleBar.addSubview(newChatButton)
        self.newChatButton = newChatButton

        let sep = NSView(frame: NSRect(x: 0, y: popoverHeight - headerHeight - 1, width: popoverWidth, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = t.separatorColor.cgColor
        sep.autoresizingMask = [.width, .minYMargin]
        container.addSubview(sep)

        let terminal = TerminalView(
            frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight - headerHeight - 1),
            characterColor: characterColor
        )
        terminal.autoresizingMask = [.width, .height]
        terminal.setPetName(name)
        terminal.onSendMessage = { [weak self, weak terminal] message in
            self?.claudeSession?.send(message: message)
            terminal?.setBusy(self?.isClaudeBusy ?? false)
        }
        terminal.onStop = { [weak self, weak terminal] in
            self?.claudeSession?.stop()
            terminal?.setBusy(false)
        }
        terminal.onAction = { [weak self] action in
            self?.handleChatAction(action)
        }
        container.addSubview(terminal)

        win.contentView = container
        popoverWindow = win
        terminalView = terminal
        popoverNameLabel = nameLabel
        popoverStatusLabel = statusLabel
        popoverStatusDot = statusDot
        shownStatusText = nil
        refreshPopoverStatus()
    }

    private func wireSession(_ session: ClaudeSession) {
        session.onText = { [weak self] text in
            self?.terminalView?.appendStreamingText(text)
        }

        session.onTurnComplete = { [weak self] in
            self?.terminalView?.setBusy(false)
            self?.playCompletionSound()
            self?.showCompletionBubble()
        }

        session.onError = { [weak self] text in
            self?.terminalView?.appendError(text)
        }

        session.onNotice = { [weak self] text in
            self?.terminalView?.appendNotice(text)
        }

        session.onToolUse = { [weak self] toolName, summary in
            self?.terminalView?.appendToolUse(toolName: toolName, summary: summary)
        }

        session.onToolResult = { [weak self] summary, isError in
            self?.terminalView?.appendToolResult(summary: summary, isError: isError)
        }
    }

    func updatePopoverPosition() {
        guard let popover = popoverWindow, isIdleForPopover else { return }
        guard let screen = activeScreen else { return }

        if let pinned = popoverPinnedOrigin {
            popover.setFrameOrigin(pinned)
            return
        }

        let charFrame = window.frame
        let popoverSize = popover.frame.size
        var x = charFrame.midX - popoverSize.width / 2
        let y = charFrame.maxY - 6

        let screenFrame = screen.frame
        x = max(screenFrame.minX + 4, min(x, screenFrame.maxX - popoverSize.width - 4))
        let clampedY = min(y, screenFrame.maxY - popoverSize.height - 4)

        popover.setFrameOrigin(NSPoint(x: x, y: clampedY))
    }

    // MARK: - Thinking Bubble

    private static let thinkingPhrases = [
        "hmm...", "thinking...", "one sec...", "ok hold on",
        "let me check", "working on it", "almost...", "bear with me",
        "on it!", "gimme a sec", "brb", "processing...",
        "hang tight", "just a moment", "figuring it out",
        "crunching...", "reading...", "looking..."
    ]

    private static let completionPhrases = [
        "done!", "all set!", "ready!", "here you go", "got it!",
        "finished!", "ta-da!", "voila!"
    ]

    private var lastPhraseUpdate: CFTimeInterval = 0
    var currentPhrase = ""
    var completionBubbleExpiry: CFTimeInterval = 0
    var showingCompletion = false

    private static let bubbleH: CGFloat = 26
    private var phraseAnimating = false

    func updateThinkingBubble() {
        let now = CACurrentMediaTime()

        if showingCompletion {
            // Hidden while the chat is open; closePopover restarts the countdown.
            if isIdleForPopover {
                hideBubble()
                return
            }
            if now >= completionBubbleExpiry {
                showingCompletion = false
                hideBubble()
                return
            }
            showBubble(text: currentPhrase, isCompletion: true)
            return
        }

        if isClaudeBusy && !isIdleForPopover {
            let oldPhrase = currentPhrase
            updateThinkingPhrase()
            if currentPhrase != oldPhrase && !oldPhrase.isEmpty && !phraseAnimating {
                animatePhraseChange(to: currentPhrase, isCompletion: false)
            } else if !phraseAnimating {
                showBubble(text: currentPhrase, isCompletion: false)
            }
        } else if !showingCompletion {
            hideBubble()
        }
    }

    private func hideBubble() {
        if thinkingBubbleWindow?.isVisible ?? false {
            thinkingBubbleWindow?.orderOut(nil)
        }
    }

    private func animatePhraseChange(to newText: String, isCompletion: Bool) {
        guard let win = thinkingBubbleWindow, win.isVisible,
              let label = win.contentView?.viewWithTag(100) as? NSTextField else {
            showBubble(text: newText, isCompletion: isCompletion)
            return
        }
        phraseAnimating = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            label.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.showBubble(text: newText, isCompletion: isCompletion)
            label.alphaValue = 0.0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                label.animator().alphaValue = 1.0
            }, completionHandler: {
                self?.phraseAnimating = false
            })
        })
    }

    func showBubble(text: String, isCompletion: Bool) {
        let t = resolvedTheme
        if thinkingBubbleWindow == nil {
            createThinkingBubble()
        }

        let h = Self.bubbleH
        let padding: CGFloat = 16
        let font = t.bubbleFont
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let bubbleW = max(ceil(textSize.width) + padding * 2, 48)

        let charFrame = window.frame
        let x = charFrame.midX - bubbleW / 2
        let y = charFrame.origin.y + charFrame.height * 0.88
        thinkingBubbleWindow?.setFrame(CGRect(x: x, y: y, width: bubbleW, height: h), display: false)

        let borderColor = isCompletion ? t.bubbleCompletionBorder.cgColor : t.bubbleBorder.cgColor
        let textColor = isCompletion ? t.bubbleCompletionText : t.bubbleText

        if let container = thinkingBubbleWindow?.contentView {
            container.frame = NSRect(x: 0, y: 0, width: bubbleW, height: h)
            container.layer?.backgroundColor = t.bubbleBg.cgColor
            container.layer?.cornerRadius = t.bubbleCornerRadius
            container.layer?.borderColor = borderColor
            if let label = container.viewWithTag(100) as? NSTextField {
                label.font = font
                let lineH = ceil(textSize.height)
                let labelY = round((h - lineH) / 2) - 1
                label.frame = NSRect(x: 0, y: labelY, width: bubbleW, height: lineH + 2)
                label.stringValue = text
                label.textColor = textColor
            }
        }

        if !(thinkingBubbleWindow?.isVisible ?? false) {
            thinkingBubbleWindow?.alphaValue = 1.0
            thinkingBubbleWindow?.orderFrontRegardless()
        }
    }

    private func updateThinkingPhrase() {
        let now = CACurrentMediaTime()
        if currentPhrase.isEmpty || now - lastPhraseUpdate > Double.random(in: 3.0...5.0) {
            var next = Self.thinkingPhrases.randomElement() ?? "..."
            while next == currentPhrase && Self.thinkingPhrases.count > 1 {
                next = Self.thinkingPhrases.randomElement() ?? "..."
            }
            currentPhrase = next
            lastPhraseUpdate = now
        }
    }

    func showCompletionBubble() {
        currentPhrase = Self.completionPhrases.randomElement() ?? "done!"
        showingCompletion = true
        bubbleIsMischief = false
        completionBubbleExpiry = CACurrentMediaTime() + 3.0
        lastPhraseUpdate = 0
        phraseAnimating = false
        if !isIdleForPopover {
            showBubble(text: currentPhrase, isCompletion: true)
        }
    }

    private func createThinkingBubble() {
        let t = resolvedTheme
        let w: CGFloat = 80
        let h = Self.bubbleH
        let win = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: w, height: h),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 5)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.bubbleBg.cgColor
        container.layer?.cornerRadius = t.bubbleCornerRadius
        container.layer?.borderWidth = 1
        container.layer?.borderColor = t.bubbleBorder.cgColor

        let font = t.bubbleFont
        let lineH = ceil(("Xg" as NSString).size(withAttributes: [.font: font]).height)
        let labelY = round((h - lineH) / 2) - 1

        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = t.bubbleText
        label.alignment = .center
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.frame = NSRect(x: 0, y: labelY, width: w, height: lineH + 2)
        label.tag = 100
        container.addSubview(label)

        win.contentView = container
        thinkingBubbleWindow = win
    }

    // MARK: - Completion Sound

    static var soundsEnabled = true

    private static let completionSounds: [(name: String, ext: String)] = [
        ("ping-aa", "mp3"), ("ping-bb", "mp3"), ("ping-cc", "mp3"),
        ("ping-dd", "mp3"), ("ping-ee", "mp3"), ("ping-ff", "mp3"),
        ("ping-gg", "mp3"), ("ping-hh", "mp3"), ("ping-jj", "m4a")
    ]
    private static var lastSoundIndex: Int = -1

    func playCompletionSound() {
        guard Self.soundsEnabled else { return }
        var idx: Int
        repeat {
            idx = Int.random(in: 0..<Self.completionSounds.count)
        } while idx == Self.lastSoundIndex && Self.completionSounds.count > 1
        Self.lastSoundIndex = idx

        let s = Self.completionSounds[idx]
        if let url = Bundle.main.url(forResource: s.name, withExtension: s.ext, subdirectory: "Sounds"),
           let sound = NSSound(contentsOf: url, byReference: true) {
            sound.play()
        }
    }

    // MARK: - Hover Interaction
    
    func handleMouseEntered() {
        guard !isIdleForPopover && !isOnboarding else { return }
        let now = CACurrentMediaTime()
        isHovered = true

        // Play one of the pet sounds on hover with cooldown.
        if now - lastHoverSoundTime > 1.2 {
            playCompletionSound()
            lastHoverSoundTime = now
        }
        
        if !hoverReactionShown {
            hoverReactionShown = true
            blurt(Self.hoverPhrases, for: 2.0)
        }
    }
    
    func handleMouseExited() {
        isHovered = false
        hoverReactionShown = false
        if !isClaudeBusy && !showingCompletion {
            hideBubble()
        }
    }
    
    // MARK: - Walking

    private func startWalk(_ forced: Antic? = nil) {
        antic = forced ?? pickAntic()
        isPaused = false
        isWalking = true
        walkStartTime = CACurrentMediaTime()
        walkStartX = positionX
        walkStartY = positionY
        walkFrameInterval = 0.3
        hopCount = 0
        hopHeight = 0
        wiggleFlips = 0

        switch antic {
        case .stroll:
            walkDuration = strollDuration
            pickTarget(distance: 0.1...0.4, yChance: 0.5, yRange: 0.15)
        case .zoomies:
            walkDuration = .random(in: 1.6...2.4)
            walkFrameInterval = 0.09
            hopCount = 3
            hopHeight = 10
            pickTarget(distance: 0.35...0.6, yChance: 0.7, yRange: 0.25)
            blurt(["wheee!", "zoom zoom!", "nyoom!", "can't stop!", "hehehe!"])
        case .sneak:
            walkDuration = .random(in: 6.0...9.0)
            walkFrameInterval = 0.55
            pickTarget(distance: 0.08...0.2, yChance: 0.3, yRange: 0.08)
            blurt(["shhh...", "*sneaks*", "tiptoe...", "nobody saw that"])
        case .hop:
            walkDuration = .random(in: 1.6...2.6)
            hopCount = Int.random(in: 2...4)
            hopHeight = .random(in: 18...30)
            pickTarget(distance: 0.0...0.08, yChance: 0, yRange: 0)
            blurt(["boing!", "hup hup!", "ih!", "*bounces*"])
        case .wiggle:
            walkDuration = .random(in: 1.2...2.0)
            walkFrameInterval = 0.12
            walkEndX = walkStartX
            walkEndY = walkStartY
            blurt(["hehehe", "meega nala kweesta!", "*mischief*", "naga!", "ih ih ih!"])
        case .chase:
            let target = cursorTarget() ?? CGPoint(x: walkStartX, y: walkStartY)
            walkEndX = target.x
            walkEndY = target.y
            goingRight = walkEndX >= walkStartX
            walkDuration = max(1.5, Double(hypot(walkEndX - walkStartX, walkEndY - walkStartY)) * 6)
            walkFrameInterval = 0.15
            blurt(["gaba!", "gonna get you!", "*chases*"], for: 1.2)
        case .flee:
            let cursor = NSEvent.mouseLocation
            goingRight = cursor.x < window.frame.midX
            if (goingRight && walkStartX > 0.8) || (!goingRight && walkStartX < 0.2) { goingRight.toggle() }
            walkDuration = .random(in: 1.2...1.8)
            walkFrameInterval = 0.08
            hopCount = 2
            hopHeight = 8
            let dx = CGFloat.random(in: 0.2...0.35)
            walkEndX = goingRight ? min(walkStartX + dx, 0.95) : max(walkStartX - dx, 0.05)
            let dy = CGFloat.random(in: 0.05...0.15) * (cursor.y < window.frame.midY ? 1 : -1)
            walkEndY = min(max(walkStartY + dy, 0.05), 0.7)
            blurt(["nope!", "can't catch me!", "hehehe!", "nyeh!", "ha!"])
        }

        updateFlip()
        startWalkSpriteTimer()
    }

    private func pickAntic() -> Antic {
        let n = naughtiness
        var options: [(Antic, Double)] = [
            (.stroll, 1 + 3 * (1 - n)),
            (.zoomies, 2 * n),
            (.sneak, 0.3 + n),
            (.hop, 0.5 + 1.5 * n),
            (.wiggle, 1.5 * n)
        ]
        if cursorTarget() != nil { options.append((.chase, n)) }
        var roll = Double.random(in: 0..<options.reduce(0) { $0 + $1.1 })
        for (option, weight) in options {
            if roll < weight { return option }
            roll -= weight
        }
        return .stroll
    }

    private func pickTarget(distance: ClosedRange<CGFloat>, yChance: Double, yRange: CGFloat) {
        if positionX > 0.85 {
            goingRight = false
        } else if positionX < 0.15 {
            goingRight = true
        } else {
            goingRight = Bool.random()
        }
        let dx = CGFloat.random(in: distance)
        walkEndX = goingRight ? min(walkStartX + dx, 0.95) : max(walkStartX - dx, 0.05)
        if Double.random(in: 0..<1) < yChance {
            walkEndY = min(max(walkStartY + .random(in: -yRange...yRange), 0.05), 0.7)
        } else {
            walkEndY = walkStartY
        }
    }

    // Normalized position that puts the pet under the cursor, if the cursor is on the pet's screen.
    private func cursorTarget() -> CGPoint? {
        guard let frame = activeScreen?.frame else { return nil }
        let cursor = NSEvent.mouseLocation
        guard frame.contains(cursor) else { return nil }
        let x = (cursor.x - displayWidth / 2 - frame.minX) / max(frame.width - displayWidth, 1)
        let y = (cursor.y - displayHeight / 2 - frame.minY) / frame.height
        return CGPoint(x: min(max(x, 0.05), 0.95), y: min(max(y, 0.05), 0.7))
    }

    private func cursorJustCameNear() -> Bool {
        let cursor = NSEvent.mouseLocation
        let near = hypot(cursor.x - window.frame.midX, cursor.y - window.frame.midY) < 170
        defer { cursorWasNear = near }
        return near && !cursorWasNear
    }

    private func blurt(_ phrases: [String], for duration: CFTimeInterval = 1.8) {
        // Never cover Claude's thinking/done bubbles or the onboarding greeting.
        guard !isClaudeBusy, !isOnboarding, !showingCompletion || bubbleIsMischief else { return }
        currentPhrase = phrases.randomElement() ?? ""
        showingCompletion = true
        bubbleIsMischief = true
        completionBubbleExpiry = CACurrentMediaTime() + duration
        showBubble(text: currentPhrase, isCompletion: true)
    }

    func enterPause() {
        isWalking = false
        isPaused = true
        showIdleSprite()
        // Naughtier pets sit still for less time.
        let delay = Double.random(in: 1.5...4.0) * (1 - 0.4 * naughtiness)
        pauseEndTime = CACurrentMediaTime() + delay
    }

    func updateFlip() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if goingRight {
            spriteLayer.transform = CATransform3DIdentity
        } else {
            spriteLayer.transform = CATransform3DMakeScale(-1, 1, 1)
        }
        spriteLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        CATransaction.commit()
    }

    func strollProgress(at time: CFTimeInterval) -> CGFloat {
        let dIn = fullSpeedStart - accelStart
        let dLin = decelStart - fullSpeedStart
        let dOut = walkStop - decelStart
        let v = 1.0 / (dIn / 2.0 + dLin + dOut / 2.0)

        if time <= accelStart {
            return 0.0
        } else if time <= fullSpeedStart {
            let t = time - accelStart
            return CGFloat(v * t * t / (2.0 * dIn))
        } else if time <= decelStart {
            let easeInDist = v * dIn / 2.0
            let t = time - fullSpeedStart
            return CGFloat(easeInDist + v * t)
        } else if time <= walkStop {
            let easeInDist = v * dIn / 2.0
            let linearDist = v * dLin
            let t = time - decelStart
            return CGFloat(easeInDist + linearDist + v * (t - t * t / (2.0 * dOut)))
        } else {
            return 1.0
        }
    }

    // MARK: - Frame Update

    private var activeScreen: NSScreen? { controller?.activeScreen ?? NSScreen.main }

    func update() {
        guard let screen = activeScreen else { return }
        let screenFrame = screen.frame
        refreshPopoverStatus()

        // The user is carrying the pet; CharacterContentView moves the window.
        if isBeingDragged {
            keepLegsMovingWhileDragged()
            updatePopoverPosition()
            updateThinkingBubble()
            return
        }

        let cursorArrived = cursorJustCameNear()

        // Sit still while the chat box is open.
        if isIdleForPopover {
            placeWindow(in: screenFrame)
            updatePopoverPosition()
            updateThinkingBubble()
            return
        }

        let now = CACurrentMediaTime()

        if cursorArrived, !isOnboarding, now >= fleeCooldownEnd,
           !isWalking || antic == .stroll || antic == .sneak,
           Double.random(in: 0..<1) < 0.45 * naughtiness {
            fleeCooldownEnd = now + 12
            startWalk(.flee)
        }

        if isPaused {
            if now >= pauseEndTime {
                startWalk()
            } else {
                placeWindow(in: screenFrame)
                updateThinkingBubble()
                return
            }
        }

        if isWalking {
            let elapsed = now - walkStartTime
            // Stretch the stroll's ease-in/out curve over this antic's duration.
            let curveTime = min(elapsed, walkDuration) * strollDuration / walkDuration

            let walkNorm = elapsed >= walkDuration ? 1.0 : strollProgress(at: curveTime)
            
            // Interpolate X position
            positionX = walkStartX + (walkEndX - walkStartX) * CGFloat(walkNorm)
            
            // Interpolate Y position (diagonal walks)
            positionY = walkStartY + (walkEndY - walkStartY) * CGFloat(walkNorm)

            if antic == .wiggle, Int(elapsed / 0.18) != wiggleFlips {
                wiggleFlips = Int(elapsed / 0.18)
                goingRight.toggle()
                updateFlip()
            }

            if elapsed >= walkDuration {
                if antic == .chase {
                    blurt(["boop!", "gotcha!", "tag, you're it!"])
                    playCompletionSound()
                }
                enterPause()
                return
            }

            let progress = elapsed / walkDuration
            let lift = hopHeight * CGFloat(abs(sin(Double.pi * Double(hopCount) * progress)))
            placeWindow(in: screenFrame, lift: lift)
        }

        updateThinkingBubble()
    }

    private func placeWindow(in screenFrame: CGRect, lift: CGFloat = 0) {
        let x = screenFrame.minX + (screenFrame.width - displayWidth) * positionX
        let y = screenFrame.minY + screenFrame.height * positionY + lift
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
