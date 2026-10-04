import AppKit

class ClaudePetController {
    private(set) var pet: WalkerCharacter?
    private var displayLink: CVDisplayLink?
    var pinnedScreenIndex: Int = -1
    private static let onboardingKey = "hasCompletedOnboarding"
    private static let petVisibleKey = "petVisible"
    private static let petNameKey = "petName"
    private static let defaultPetName = "Stitch"
    private static let maxNameLength = 24

    func start() {
        // Guard against accidental double-start creating a duplicate pet.
        if pet != nil { return }

        UserDefaults.standard.register(defaults: [Self.petVisibleKey: true])

        let pet = WalkerCharacter(
            spriteIdleName: "stitch_idle",
            spriteWalk1Name: "stitch_walk1",
            spriteWalk2Name: "stitch_walk2"
        )
        pet.displayHeight = 160
        pet.accelStart = 0.5
        pet.fullSpeedStart = 1.0
        pet.decelStart = 7.5
        pet.walkStop = 8.0
        pet.videoDuration = 8.75
        pet.characterColor = NSColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        pet.naughtiness = 1.0
        pet.name = UserDefaults.standard.string(forKey: Self.petNameKey) ?? Self.defaultPetName
        pet.positionX = 0.35
        pet.positionY = 0.3
        pet.pauseEndTime = CACurrentMediaTime() + Double.random(in: 0.5...1.5)
        pet.setup()
        pet.controller = self
        self.pet = pet

        if !UserDefaults.standard.bool(forKey: Self.petVisibleKey) {
            pet.window.orderOut(nil)
            pet.pauseSpriteForMenuHide()
        }

        startDisplayLink()

        if !UserDefaults.standard.bool(forKey: Self.onboardingKey) {
            triggerOnboarding()
        }
    }

    func setPetVisible(_ visible: Bool) {
        guard let pet else { return }
        if visible {
            pet.window.orderFrontRegardless()
        } else {
            if pet.isIdleForPopover { pet.closePopover() }
            pet.window.orderOut(nil)
            pet.pauseSpriteForMenuHide()
        }
        UserDefaults.standard.set(visible, forKey: Self.petVisibleKey)
    }

    func promptRename() {
        guard let pet else { return }
        let alert = NSAlert()
        alert.messageText = "Name your pet"
        alert.informativeText = "Pick any name. It shows in the chat and in the menu."
        let field = NSTextField(string: pet.name)
        field.placeholderString = Self.defaultPetName
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Blank resets to the default; long names would overflow the chat header.
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? Self.defaultPetName : String(trimmed.prefix(Self.maxNameLength))
        UserDefaults.standard.set(name, forKey: Self.petNameKey)
        pet.rename(to: name)
    }

    private func triggerOnboarding() {
        guard let pet else { return }
        pet.isOnboarding = true
        // Show greeting after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            pet.currentPhrase = "aloha!"
            pet.showingCompletion = true
            pet.completionBubbleExpiry = CACurrentMediaTime() + 600
            pet.showBubble(text: "aloha!", isCompletion: true)
            pet.playCompletionSound()
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        pet?.isOnboarding = false
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
        guard let pet, pet.window.isVisible else { return }
        pet.update()
    }

    deinit {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }
}
