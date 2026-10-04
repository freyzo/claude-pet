import SwiftUI
import AppKit
import Sparkle

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
    private weak var petVisibilityMenuItem: NSMenuItem?
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a Claude process that just died must be a recoverable error, not a crash.
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.accessory)
        controller = ClaudePetController()
        controller?.start()
        setupMenuBar()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.pet?.claudeSession?.terminate()
    }

    // MARK: - Menu Bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "dog", accessibilityDescription: "claude-pet")
        }

        let menu = NSMenu()
        menu.delegate = self

        let petItem = NSMenuItem(title: "Show Pet", action: #selector(togglePet(_:)), keyEquivalent: "1")
        menu.addItem(petItem)
        petVisibilityMenuItem = petItem

        menu.addItem(NSMenuItem(title: "Rename Pet…", action: #selector(renamePet), keyEquivalent: "r"))

        syncPetMenuItem()

        menu.addItem(NSMenuItem.separator())

        let soundItem = NSMenuItem(title: "Sounds", action: #selector(toggleSounds(_:)), keyEquivalent: "")
        soundItem.state = .on
        menu.addItem(soundItem)

        // Theme submenu
        let themeItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for (i, theme) in PopoverTheme.allThemes.enumerated() {
            let item = NSMenuItem(title: theme.name, action: #selector(switchTheme(_:)), keyEquivalent: "")
            item.tag = i
            item.state = i == 0 ? .on : .off
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        // Display submenu
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let autoItem = NSMenuItem(title: "Auto (Main Display)", action: #selector(switchDisplay(_:)), keyEquivalent: "")
        autoItem.tag = -1
        autoItem.state = .on
        displayMenu.addItem(autoItem)
        displayMenu.addItem(NSMenuItem.separator())
        for (i, screen) in NSScreen.screens.enumerated() {
            let name = screen.localizedName
            let item = NSMenuItem(title: name, action: #selector(switchDisplay(_:)), keyEquivalent: "")
            item.tag = i
            item.state = .off
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

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

        if let themeMenu = sender.menu {
            for item in themeMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }

        guard let pet = controller?.pet else { return }
        let wasOpen = pet.isIdleForPopover
        if wasOpen { pet.popoverWindow?.orderOut(nil) }
        pet.popoverWindow = nil
        pet.terminalView = nil
        pet.thinkingBubbleWindow = nil
        if wasOpen {
            pet.createPopoverWindow()
            if let session = pet.claudeSession, !session.history.isEmpty {
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
        let idx = sender.tag
        controller?.pinnedScreenIndex = idx

        if let displayMenu = sender.menu {
            for item in displayMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }
    }

    @objc func togglePet(_ sender: NSMenuItem) {
        guard let pet = controller?.pet else { return }
        controller?.setPetVisible(!pet.window.isVisible)
        syncPetMenuItem()
    }

    @objc func renamePet() {
        controller?.promptRename()
    }

    private func syncPetMenuItem() {
        guard let pet = controller?.pet else { return }
        petVisibilityMenuItem?.title = "Show \(pet.name)"
        petVisibilityMenuItem?.state = pet.window.isVisible ? .on : .off
    }

    @objc func toggleSounds(_ sender: NSMenuItem) {
        WalkerCharacter.soundsEnabled.toggle()
        sender.state = WalkerCharacter.soundsEnabled ? .on : .off
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        syncPetMenuItem()
    }
}
