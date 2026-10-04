import AppKit
import QuartzCore
import os

// Every UserDefaults key the app stores. Values are already on users' disks: never change them.
enum DefaultsKey {
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let petVisible = "petVisible"
    static let petName = "petName"
    static let claudeVisible = "petVisibleClaude"
    static let claudeName = "petNameClaude"
    static let stitchCorner = "petCornerStitch"  // "left" / "right"; absent = roaming
    static let claudeCorner = "petCornerClaude"
    static let theme = "theme"
    static let soundsEnabled = "soundsEnabled"
    static let display = "display"
    static let workingFolder = "workingFolder"
    static let allowEdits = "allowEdits"
    static let petsPaused = "petsPaused"
    static let provider = "aiProvider"
}

// One clock per pet: a pet's view link follows it across screens and idles while it's hidden.
private final class FrameClockTarget: NSObject {
    weak var pet: WalkerCharacter?  // CADisplayLink retains its target, so keep the pet weak
    private var isSmooth = false
    // Full frame rate only while moving; sitting still needs ~10 checks a second.
    private static let smoothRate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    static let restingRate = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 10)

    init(_ pet: WalkerCharacter) { self.pet = pet }

    @objc func step(_ link: CADisplayLink) {
        guard let pet, pet.window?.isVisible == true else { return }
        pet.update()
        if pet.needsSmoothFrames != isSmooth {
            isSmooth.toggle()
            link.preferredFrameRateRange = isSmooth ? Self.smoothRate : Self.restingRate
        }
    }
}

private struct PetSpec {
    let sprite: String  // asset prefix: <sprite>_idle, _walk1, _walk2
    let defaultName: String
    let nameKey: String
    let visibleKey: String
    let cornerKey: String
    let color: NSColor
    let naughtiness: Double
    let phrases: PetPhrases
    let start: CGPoint
    let firstPause: ClosedRange<Double>
}

class ClaudePetController {
    private(set) var pets: [WalkerCharacter] = []
    private var displayLinks: [CADisplayLink] = []
    private(set) var pinnedScreenName: String?
    private(set) var activity: PetActivityMonitor?
    /// Supplies the menu shown when a pet is right-clicked (the status bar menu).
    var contextMenuProvider: (() -> NSMenu?)?
    private static let maxNameLength = 24
    private static let specs = [
        PetSpec(sprite: "stitch", defaultName: "Stitch", nameKey: DefaultsKey.petName, visibleKey: DefaultsKey.petVisible,
                cornerKey: DefaultsKey.stitchCorner,
                color: NSColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0), naughtiness: 1.0, phrases: .stitch,
                start: CGPoint(x: 0.35, y: 0.3), firstPause: 0.5...1.5),
        PetSpec(sprite: "claude", defaultName: "Claude", nameKey: DefaultsKey.claudeName, visibleKey: DefaultsKey.claudeVisible,
                cornerKey: DefaultsKey.claudeCorner,
                color: NSColor(red: 1.0, green: 0.42, blue: 0.0, alpha: 1.0), naughtiness: 0.4, phrases: .robot,
                start: CGPoint(x: 0.62, y: 0.28), firstPause: 0.8...2.2)
    ]

    func start() {
        // Guard against accidental double-start creating duplicate pets.
        if !pets.isEmpty { return }

        UserDefaults.standard.register(defaults: [DefaultsKey.petVisible: true, DefaultsKey.claudeVisible: true])
        pinnedScreenName = UserDefaults.standard.string(forKey: DefaultsKey.display)

        for spec in Self.specs {
            let pet = WalkerCharacter(
                spriteIdleName: "\(spec.sprite)_idle",
                spriteWalk1Name: "\(spec.sprite)_walk1",
                spriteWalk2Name: "\(spec.sprite)_walk2"
            )
            pet.displayHeight = 160
            pet.accelStart = 0.5
            pet.fullSpeedStart = 1.0
            pet.decelStart = 7.5
            pet.walkStop = 8.0
            pet.strollDuration = 8.75
            pet.characterColor = spec.color
            pet.naughtiness = spec.naughtiness
            pet.phrases = spec.phrases
            pet.name = UserDefaults.standard.string(forKey: spec.nameKey) ?? spec.defaultName
            pet.positionX = spec.start.x
            pet.positionY = spec.start.y
            pet.pauseEndTime = CACurrentMediaTime() + Double.random(in: spec.firstPause)
            pet.setup()
            pet.controller = self
            pet.cornerSlot = pets.count
            if let side = UserDefaults.standard.string(forKey: spec.cornerKey) {
                pet.goToCorner(onRight: side == "right", animated: false)
            }
            pets.append(pet)

            if !UserDefaults.standard.bool(forKey: spec.visibleKey) {
                pet.window.orderOut(nil)
                pet.pauseSpriteForMenuHide()
            }
            startDisplayLink(for: pet)
        }

        let activity = PetActivityMonitor()
        activity.userPaused = UserDefaults.standard.bool(forKey: DefaultsKey.petsPaused)
        activity.onChange = { [weak self] in self?.applyActivity() }
        self.activity = activity
        applyActivity()

        if !UserDefaults.standard.bool(forKey: DefaultsKey.hasCompletedOnboarding) {
            triggerOnboarding()
        }
    }

    private func applyActivity() {
        guard let activity else { return }
        pets.forEach { $0.isCalm = activity.isCalm }
        // Nobody can see the screen: no frame work at all until they can.
        displayLinks.forEach { $0.isPaused = !activity.isScreenVisible }
    }

    func setPetsPaused(_ paused: Bool) {
        UserDefaults.standard.set(paused, forKey: DefaultsKey.petsPaused)
        activity?.userPaused = paused
    }

    func setParked(_ pet: WalkerCharacter, _ parked: Bool) {
        if parked { pet.goToCorner() } else { pet.leaveCorner() }
        petPlacementChanged(pet)
    }

    /// Saves which corner (if any) a pet is parked in.
    func petPlacementChanged(_ pet: WalkerCharacter) {
        guard let spec = spec(for: pet) else { return }
        let side: String? = pet.isParked ? (pet.parkedOnRight ? "right" : "left") : nil
        UserDefaults.standard.set(side, forKey: spec.cornerKey)
        Logger.app.info("\(spec.defaultName, privacy: .public) \(side.map { "parked \($0)" } ?? "roaming", privacy: .public)")
    }

    private func spec(for pet: WalkerCharacter) -> PetSpec? {
        pets.firstIndex { $0 === pet }.map { Self.specs[$0] }
    }

    func setVisible(_ pet: WalkerCharacter, _ visible: Bool) {
        guard let spec = spec(for: pet) else { return }
        if visible {
            pet.window.orderFrontRegardless()
        } else {
            if pet.isIdleForPopover { pet.closePopover() }
            pet.window.orderOut(nil)
            pet.pauseSpriteForMenuHide()
        }
        UserDefaults.standard.set(visible, forKey: spec.visibleKey)
        Logger.app.info("\(spec.defaultName, privacy: .public) \(visible ? "shown" : "hidden", privacy: .public)")
    }

    func setPinnedScreen(name: String?) {
        pinnedScreenName = name
        UserDefaults.standard.set(name, forKey: DefaultsKey.display)
    }

    // MARK: - Claude Settings

    var provider: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.provider) ?? "") ?? .default
    }

    func makeChatEngine() -> ChatEngine {
        provider == .copilot ? CopilotSession() : ClaudeSession()
    }

    func setProvider(_ newProvider: AIProvider) {
        guard newProvider != provider else { return }
        UserDefaults.standard.set(newProvider.rawValue, forKey: DefaultsKey.provider)
        Logger.app.info("Assistant: \(newProvider.rawValue, privacy: .public)")
        pets.forEach { $0.switchChatProvider(notice: "**Now chatting with \(newProvider.menuTitle).** This is a fresh conversation.") }
    }

    var workingFolder: URL {
        if let path = UserDefaults.standard.string(forKey: DefaultsKey.workingFolder) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    var hasCustomWorkingFolder: Bool {
        UserDefaults.standard.string(forKey: DefaultsKey.workingFolder) != nil
    }

    /// nil = home folder.
    func setWorkingFolder(_ url: URL?) {
        let old = workingFolder
        UserDefaults.standard.set(url?.path, forKey: DefaultsKey.workingFolder)
        guard workingFolder.standardizedFileURL != old.standardizedFileURL else { return }
        Logger.app.info("Working folder changed (custom: \(self.hasCustomWorkingFolder, privacy: .public))")
        pets.forEach { $0.applyClaudeSettings(
            newConversation: true,
            notice: "**Now working in \(ClaudeSession.displayPath(workingFolder)).** Starting a fresh chat there."
        ) }
    }

    var allowsEdits: Bool {
        UserDefaults.standard.object(forKey: DefaultsKey.allowEdits) as? Bool ?? true
    }

    func setAllowsEdits(_ allowed: Bool) {
        guard allowed != allowsEdits else { return }
        UserDefaults.standard.set(allowed, forKey: DefaultsKey.allowEdits)
        Logger.app.info("Edits & commands \(allowed ? "on" : "off", privacy: .public)")
        pets.forEach { $0.applyClaudeSettings(
            newConversation: false,
            notice: allowed
                ? "**Edits & commands on.** \(provider.assistantName) can change files and run commands in \(ClaudeSession.displayPath(workingFolder))."
                : "**Edits & commands off.** \(provider.assistantName) can still read and answer, but won't change files or run commands."
        ) }
    }

    func promptRename(_ pet: WalkerCharacter) {
        guard let spec = spec(for: pet) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(pet.name)"
        alert.informativeText = "Pick any name. It shows in the chat and in the menu."
        let field = NSTextField(string: pet.name)
        field.placeholderString = spec.defaultName
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Blank resets to the default; long names would overflow the chat header.
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? spec.defaultName : String(trimmed.prefix(Self.maxNameLength))
        UserDefaults.standard.set(name, forKey: spec.nameKey)
        pet.rename(to: name)
    }

    private func triggerOnboarding() {
        guard let pet = pets.first else { return }
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
        UserDefaults.standard.set(true, forKey: DefaultsKey.hasCompletedOnboarding)
        pets.forEach { $0.isOnboarding = false }
    }

    // MARK: - Frame Clock

    private func startDisplayLink(for pet: WalkerCharacter) {
        guard let view = pet.window?.contentView else { return }
        let link = view.displayLink(target: FrameClockTarget(pet), selector: #selector(FrameClockTarget.step(_:)))
        link.preferredFrameRateRange = FrameClockTarget.restingRate
        link.add(to: .main, forMode: .common)
        displayLinks.append(link)
    }

    var activeScreen: NSScreen? {
        // A pinned monitor that's unplugged falls back to the main screen until it returns.
        if let name = pinnedScreenName, let screen = NSScreen.screens.first(where: { $0.localizedName == name }) {
            return screen
        }
        return NSScreen.main
    }

    deinit {
        displayLinks.forEach { $0.invalidate() }
    }
}
