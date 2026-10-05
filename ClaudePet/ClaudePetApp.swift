import SwiftUI
import AppKit
import ServiceManagement
import Sparkle
import os

@main
struct ClaudePetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: ClaudePetController?
    var statusItem: NSStatusItem?
    private var petVisibilityItems: [NSMenuItem] = []
    private var renameItems: [NSMenuItem] = []
    private var chatItems: [NSMenuItem] = []
    private var cornerItems: [NSMenuItem] = []
    private weak var pauseItem: NSMenuItem?
    private weak var restingInfoItem: NSMenuItem?
    private weak var displayMenu: NSMenu?
    private weak var claudeMenu: NSMenu?
    private weak var launchAtLoginItem: NSMenuItem?
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a Claude process that just died must be a recoverable error, not a crash.
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.accessory)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Logger.app.info("claude-pet \(version, privacy: .public) launched")
        restoreSettings()
        controller = ClaudePetController()
        controller?.start()
        setupMenuBar()
        controller?.contextMenuProvider = { [weak self] in self?.statusItem?.menu }
    }

    private func restoreSettings() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [DefaultsKey.soundsEnabled: true])
        WalkerCharacter.soundsEnabled = defaults.bool(forKey: DefaultsKey.soundsEnabled)
        if let saved = defaults.string(forKey: DefaultsKey.theme),
           let theme = PopoverTheme.allThemes.first(where: { $0.name == saved }) {
            PopoverTheme.current = theme
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.pets.forEach { $0.chatSession?.terminate() }
    }

    // MARK: - Menu Bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "dog", accessibilityDescription: "claude-pet")
            button.setAccessibilityLabel("claude-pet")
        }

        let menu = NSMenu()
        menu.delegate = self

        for i in (controller?.pets ?? []).indices {
            let item = NSMenuItem(title: "Chat", action: #selector(openChat(_:)), keyEquivalent: "")
            item.tag = i
            menu.addItem(item)
            chatItems.append(item)
        }
        menu.addItem(NSMenuItem.separator())

        let renameItem = NSMenuItem(title: "Rename Pet", action: nil, keyEquivalent: "")
        let renameMenu = NSMenu()
        renameItem.submenu = renameMenu
        for (i, _) in (controller?.pets ?? []).enumerated() {
            let showItem = NSMenuItem(title: "Show Pet", action: #selector(togglePet(_:)), keyEquivalent: "\(i + 1)")
            showItem.tag = i
            menu.addItem(showItem)
            petVisibilityItems.append(showItem)

            let item = NSMenuItem(title: "Pet", action: #selector(renamePet(_:)), keyEquivalent: "")
            item.tag = i
            renameMenu.addItem(item)
            renameItems.append(item)
        }
        menu.addItem(renameItem)

        for i in (controller?.pets ?? []).indices {
            let item = NSMenuItem(title: "Cozy Corner", action: #selector(toggleCorner(_:)), keyEquivalent: "")
            item.tag = i
            menu.addItem(item)
            cornerItems.append(item)
        }

        let pause = NSMenuItem(title: "Pause Pets", action: #selector(togglePausePets(_:)), keyEquivalent: "p")
        menu.addItem(pause)
        pauseItem = pause
        let resting = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        resting.isEnabled = false
        menu.addItem(resting)
        restingInfoItem = resting

        syncPetMenuItems()

        menu.addItem(NSMenuItem.separator())

        let soundItem = NSMenuItem(title: "Sounds", action: #selector(toggleSounds(_:)), keyEquivalent: "")
        soundItem.state = WalkerCharacter.soundsEnabled ? .on : .off
        menu.addItem(soundItem)

        // Theme submenu
        let themeItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for (i, theme) in PopoverTheme.allThemes.enumerated() {
            let item = NSMenuItem(title: theme.name, action: #selector(switchTheme(_:)), keyEquivalent: "")
            item.tag = i
            item.state = theme.name == PopoverTheme.current.name ? .on : .off
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        // Display submenu: rebuilt on every open so plugged/unplugged monitors show up.
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.delegate = self
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)
        self.displayMenu = displayMenu

        // Assistant submenu: which AI, where it works and what it may do. Rebuilt on open.
        let claudeItem = NSMenuItem(title: "Assistant", action: nil, keyEquivalent: "")
        let claudeMenu = NSMenu()
        claudeMenu.delegate = self
        claudeItem.submenu = claudeMenu
        menu.addItem(claudeItem)
        self.claudeMenu = claudeMenu

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        menu.addItem(loginItem)
        launchAtLoginItem = loginItem
        syncLaunchAtLoginItem()

        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Menu Actions

    @objc func switchTheme(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx < PopoverTheme.allThemes.count else { return }
        PopoverTheme.current = PopoverTheme.allThemes[idx]
        UserDefaults.standard.set(PopoverTheme.current.name, forKey: DefaultsKey.theme)

        if let themeMenu = sender.menu {
            for item in themeMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }

        for pet in controller?.pets ?? [] {
            let wasOpen = pet.isIdleForPopover
            if wasOpen { pet.popoverWindow?.orderOut(nil) }
            pet.popoverWindow = nil
            pet.terminalView = nil
            pet.thinkingBubbleWindow = nil
            guard wasOpen else { continue }
            pet.createPopoverWindow()
            if let session = pet.chatSession, !session.history.isEmpty {
                pet.terminalView?.replayHistory(session.history)
            }
            pet.updatePopoverPosition()
            pet.popoverWindow?.orderFrontRegardless()
            pet.popoverWindow?.makeKey()
            if let terminal = pet.terminalView {
                pet.popoverWindow?.makeFirstResponder(terminal.inputField)
            }
        }
    }

    @objc func switchDisplay(_ sender: NSMenuItem) {
        controller?.setPinnedScreen(name: sender.representedObject as? String)
    }

    private func rebuildDisplayMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let pinned = controller?.pinnedScreenName
        let autoItem = NSMenuItem(title: "Auto (Main Display)", action: #selector(switchDisplay(_:)), keyEquivalent: "")
        autoItem.state = pinned == nil ? .on : .off
        menu.addItem(autoItem)
        menu.addItem(NSMenuItem.separator())
        let connected = NSScreen.screens.map(\.localizedName)
        for name in connected {
            let item = NSMenuItem(title: name, action: #selector(switchDisplay(_:)), keyEquivalent: "")
            item.representedObject = name
            item.state = name == pinned ? .on : .off
            menu.addItem(item)
        }
        if let pinned, !connected.contains(pinned) {
            let missing = NSMenuItem(title: "\(pinned) (not connected)", action: nil, keyEquivalent: "")
            missing.state = .on
            menu.addItem(missing)
        }
    }

    private func rebuildClaudeMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller else { return }
        for option in AIProvider.allCases {
            let item = NSMenuItem(title: option.menuTitle, action: #selector(switchProvider(_:)), keyEquivalent: "")
            item.representedObject = option.rawValue
            item.state = option == controller.provider ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let folder = NSMenuItem(title: "Folder: \(ClaudeSession.displayPath(controller.workingFolder))", action: nil, keyEquivalent: "")
        folder.isEnabled = false
        menu.addItem(folder)
        menu.addItem(NSMenuItem(title: "Choose Folder…", action: #selector(chooseWorkingFolder), keyEquivalent: ""))
        let home = NSMenuItem(title: "Use Home Folder", action: controller.hasCustomWorkingFolder ? #selector(useHomeFolder) : nil, keyEquivalent: "")
        menu.addItem(home)
        menu.addItem(NSMenuItem.separator())
        let edits = NSMenuItem(title: "Allow Edits & Commands", action: #selector(toggleAllowEdits(_:)), keyEquivalent: "")
        edits.state = controller.allowsEdits ? .on : .off
        edits.toolTip = "Off: \(controller.provider.assistantName) can read and answer, but won't change files or run commands."
        menu.addItem(edits)
    }

    @objc func switchProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let provider = AIProvider(rawValue: raw) else { return }
        controller?.setProvider(provider)
    }

    @objc func chooseWorkingFolder() {
        guard let controller else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "\(controller.provider.assistantName) will read, change and run things inside this folder."
        panel.directoryURL = controller.workingFolder
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.setWorkingFolder(url)
    }

    @objc func useHomeFolder() {
        controller?.setWorkingFolder(nil)
    }

    @objc func toggleAllowEdits(_ sender: NSMenuItem) {
        guard let controller else { return }
        controller.setAllowsEdits(!controller.allowsEdits)
    }

    // MARK: - Launch at Login

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            Logger.app.error("Launch at Login change failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
        // macOS can ask the user to allow it in System Settings first.
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        syncLaunchAtLoginItem()
    }

    private func syncLaunchAtLoginItem() {
        launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func togglePet(_ sender: NSMenuItem) {
        guard let pets = controller?.pets, pets.indices.contains(sender.tag) else { return }
        let pet = pets[sender.tag]
        controller?.setVisible(pet, !pet.window.isVisible)
        syncPetMenuItems()
    }

    @objc func renamePet(_ sender: NSMenuItem) {
        guard let pets = controller?.pets, pets.indices.contains(sender.tag) else { return }
        controller?.promptRename(pets[sender.tag])
    }

    @objc func openChat(_ sender: NSMenuItem) {
        guard let controller, controller.pets.indices.contains(sender.tag) else { return }
        let pet = controller.pets[sender.tag]
        if !pet.window.isVisible { controller.setVisible(pet, true) }
        NSApp.activate()
        pet.openChatFromMenu()
    }

    @objc func toggleCorner(_ sender: NSMenuItem) {
        guard let controller, controller.pets.indices.contains(sender.tag) else { return }
        let pet = controller.pets[sender.tag]
        if !pet.isParked && !pet.window.isVisible { controller.setVisible(pet, true) }
        controller.setParked(pet, !pet.isParked)
        syncPetMenuItems()
    }

    @objc func togglePausePets(_ sender: NSMenuItem) {
        guard let activity = controller?.activity else { return }
        controller?.setPetsPaused(!activity.userPaused)
        syncPetMenuItems()
    }

    private func syncPetMenuItems() {
        for (i, pet) in (controller?.pets ?? []).enumerated() where i < petVisibilityItems.count {
            petVisibilityItems[i].title = "Show \(pet.name)"
            petVisibilityItems[i].state = pet.window.isVisible ? .on : .off
            renameItems[i].title = "\(pet.name)…"
            chatItems[i].title = "Chat with \(pet.name)"
            cornerItems[i].title = "Send \(pet.name) to Cozy Corner"
            cornerItems[i].toolTip = "\(pet.name) plays in a little bottom-corner spot, out of your way, until you uncheck this."
            cornerItems[i].state = pet.isParked ? .on : .off
        }
        let activity = controller?.activity
        pauseItem?.state = activity?.userPaused == true ? .on : .off
        let autoReason: String? = switch activity?.calmReason {
        case .reduceMotion: "Reduce Motion is on"
        case .lowPower: "Low Power Mode is on"
        case .hot: "your Mac is running hot"
        case .paused, nil: nil
        }
        // Explain automatic rest so it doesn't look like the pets broke.
        restingInfoItem?.title = autoReason.map { "Pets are resting: \($0)" } ?? ""
        restingInfoItem?.isHidden = autoReason == nil
    }

    @objc func toggleSounds(_ sender: NSMenuItem) {
        WalkerCharacter.soundsEnabled.toggle()
        UserDefaults.standard.set(WalkerCharacter.soundsEnabled, forKey: DefaultsKey.soundsEnabled)
        sender.state = WalkerCharacter.soundsEnabled ? .on : .off
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        syncPetMenuItems()
        // Can also be changed in System Settings → General → Login Items.
        syncLaunchAtLoginItem()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === displayMenu {
            rebuildDisplayMenu(menu)
        } else if menu === claudeMenu {
            rebuildClaudeMenu(menu)
        }
    }
}
