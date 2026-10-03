import AppKit

class ClaudePetController {
    var characters: [WalkerCharacter] = []
    private var displayLink: CVDisplayLink?
    var pinnedScreenIndex: Int = -1
    private static let onboardingKey = "hasCompletedOnboarding"
    static let stitchVisibleKey = "petVisibleStitch"
    static let claudeVisibleKey = "petVisibleClaude"

    func start() {
        // Guard against accidental double-start creating duplicate pets.
        if !characters.isEmpty { return }

        UserDefaults.standard.register(defaults: [
            Self.stitchVisibleKey: true,
            Self.claudeVisibleKey: true
        ])

        // Pet 1 / characters[0]: Stitch (`stitch_*` sprites)
        let stitch = WalkerCharacter(
            spriteIdleName: "stitch_idle",
            spriteWalk1Name: "stitch_walk1",
            spriteWalk2Name: "stitch_walk2"
        )

        stitch.displayHeight = 160
        stitch.accelStart = 0.5
        stitch.fullSpeedStart = 1.0
        stitch.decelStart = 7.5
        stitch.walkStop = 8.0
        stitch.videoDuration = 8.75
        stitch.characterColor = NSColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        stitch.naughtiness = 1.0
        stitch.positionX = 0.35
        stitch.positionY = 0.3
        stitch.pauseEndTime = CACurrentMediaTime() + Double.random(in: 0.5...1.5)
        stitch.setup()

        // Pet 2 / characters[1]: Claude (`claude_*` sprites)
        let claude = WalkerCharacter(
            spriteIdleName: "claude_idle",
            spriteWalk1Name: "claude_walk1",
            spriteWalk2Name: "claude_walk2"
        )

        claude.displayHeight = 160
        claude.accelStart = 0.5
        claude.fullSpeedStart = 1.0
        claude.decelStart = 7.5
        claude.walkStop = 8.0
        claude.videoDuration = 8.75
        claude.characterColor = NSColor(red: 1.0, green: 0.42, blue: 0.0, alpha: 1.0)
        claude.naughtiness = 0.4
        claude.positionX = 0.62
        claude.positionY = 0.28
        claude.pauseEndTime = CACurrentMediaTime() + Double.random(in: 0.8...2.2)
        claude.setup()

        characters = [stitch, claude]
        characters.forEach { $0.controller = self }

        applySavedCharacterVisibility()

        startDisplayLink()

        if !UserDefaults.standard.bool(forKey: Self.onboardingKey) {
            triggerOnboarding()
        }
    }

    /// Call after menu loads so checkmarks match windows.
    func syncVisibilityMenuItems(stitchItem: NSMenuItem?, claudeItem: NSMenuItem?) {
        guard characters.count >= 2 else { return }
        stitchItem?.state = characters[0].window.isVisible ? .on : .off
        claudeItem?.state = characters[1].window.isVisible ? .on : .off
    }

    func setCharacterVisible(index: Int, visible: Bool) {
        guard characters.indices.contains(index) else { return }
        let char = characters[index]
        if visible {
            char.window.orderFrontRegardless()
        } else {
            if char.isIdleForPopover { char.closePopover() }
            char.window.orderOut(nil)
            char.pauseSpriteForMenuHide()
        }
        let key = index == 0 ? Self.stitchVisibleKey : Self.claudeVisibleKey
        UserDefaults.standard.set(visible, forKey: key)
    }

    private func applySavedCharacterVisibility() {
        guard characters.count >= 2 else { return }
        if !UserDefaults.standard.bool(forKey: Self.stitchVisibleKey) {
            characters[0].window.orderOut(nil)
            characters[0].pauseSpriteForMenuHide()
        }
        if !UserDefaults.standard.bool(forKey: Self.claudeVisibleKey) {
            characters[1].window.orderOut(nil)
            characters[1].pauseSpriteForMenuHide()
        }
    }

    private func triggerOnboarding() {
        guard let stitch = characters.first else { return }
        stitch.isOnboarding = true
        // Show greeting after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            stitch.currentPhrase = "aloha!"
            stitch.showingCompletion = true
            stitch.completionBubbleExpiry = CACurrentMediaTime() + 600
            stitch.showBubble(text: "aloha!", isCompletion: true)
            stitch.playCompletionSound()
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        characters.forEach { $0.isOnboarding = false }
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink = displayLink else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let controller = Unmanaged<ClaudePetController>.fromOpaque(userInfo!).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.tick()
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(displayLink, callback,
                                       Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
    }

    var activeScreen: NSScreen? {
        if pinnedScreenIndex >= 0, pinnedScreenIndex < NSScreen.screens.count {
            return NSScreen.screens[pinnedScreenIndex]
        }
        return NSScreen.main
    }

    func tick() {
        let activeChars = characters.filter { $0.window.isVisible }

        let now = CACurrentMediaTime()
        let anyWalking = activeChars.contains { $0.isWalking }
        for char in activeChars {
            if char.isIdleForPopover { continue }
            if char.isPaused && now >= char.pauseEndTime && anyWalking {
                char.pauseEndTime = now + Double.random(in: 5.0...10.0)
            }
        }
        for char in activeChars {
            char.update()
        }

        let sorted = activeChars.sorted { $0.positionX < $1.positionX }
        for (i, char) in sorted.enumerated() {
            char.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + i)
        }
    }

    deinit {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }
}
