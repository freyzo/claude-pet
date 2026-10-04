import AppKit
import os

/// Decides when pets should rest (motion, energy, heat) and when nobody can see the screen (do no work at all).
final class PetActivityMonitor {
    enum CalmReason: Equatable {
        case paused, reduceMotion, lowPower, hot
    }

    var onChange: (() -> Void)?

    var userPaused = false {
        didSet { if userPaused != oldValue { publishIfChanged() } }
    }

    private var reduceMotion = false
    private var lowPower = false
    private var hot = false
    private var displaysAsleep = false
    private var screenLocked = false
    private var screenSaverRunning = false
    private var sessionInactive = false

    var calmReason: CalmReason? {
        if userPaused { return .paused }
        if reduceMotion { return .reduceMotion }
        if lowPower { return .lowPower }
        if hot { return .hot }
        return nil
    }

    var isCalm: Bool { calmReason != nil }
    var isScreenVisible: Bool { !(displaysAsleep || screenLocked || screenSaverRunning || sessionInactive) }

    private let readReduceMotion: () -> Bool
    private let readLowPower: () -> Bool
    private let readHot: () -> Bool
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var published: (CalmReason?, Bool)

    init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        processCenter: NotificationCenter = .default,
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        lowPower: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        hot: @escaping () -> Bool = { [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) }
    ) {
        readReduceMotion = reduceMotion
        readLowPower = lowPower
        readHot = hot
        published = (nil, true)
        readSystemSettings()
        published = (calmReason, isScreenVisible)

        let screenFlags: [(NotificationCenter, Notification.Name, ReferenceWritableKeyPath<PetActivityMonitor, Bool>, Bool)] = [
            (workspaceCenter, NSWorkspace.screensDidSleepNotification, \.displaysAsleep, true),
            (workspaceCenter, NSWorkspace.screensDidWakeNotification, \.displaysAsleep, false),
            (workspaceCenter, NSWorkspace.sessionDidResignActiveNotification, \.sessionInactive, true),
            (workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification, \.sessionInactive, false),
            (distributedCenter, Self.screenLocked, \.screenLocked, true),
            (distributedCenter, Self.screenUnlocked, \.screenLocked, false),
            (distributedCenter, Self.screenSaverStarted, \.screenSaverRunning, true),
            (distributedCenter, Self.screenSaverStopped, \.screenSaverRunning, false)
        ]
        for (center, name, flag, value) in screenFlags {
            observe(center, name) { $0[keyPath: flag] = value }
        }
        // Power and thermal notifications may arrive on any thread; observe(_:_:) delivers on main.
        observe(workspaceCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { $0.readSystemSettings() }
        observe(processCenter, .NSProcessInfoPowerStateDidChange) { $0.readSystemSettings() }
        observe(processCenter, ProcessInfo.thermalStateDidChangeNotification) { $0.readSystemSettings() }
    }

    deinit {
        observers.forEach { center, token in center.removeObserver(token) }
    }

    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")
    static let screenSaverStarted = Notification.Name("com.apple.screensaver.didstart")
    static let screenSaverStopped = Notification.Name("com.apple.screensaver.didstop")

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ apply: @escaping (PetActivityMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            apply(self)
            self.publishIfChanged()
        }
        observers.append((center, token))
    }

    private func readSystemSettings() {
        reduceMotion = readReduceMotion()
        lowPower = readLowPower()
        hot = readHot()
    }

    private func publishIfChanged() {
        let now = (calmReason, isScreenVisible)
        guard now.0 != published.0 || now.1 != published.1 else { return }
        published = now
        let reason = calmReason.map { "\($0)" } ?? "none"
        Logger.activity.info("Pets \(self.isCalm ? "resting" : "active", privacy: .public) (reason: \(reason, privacy: .public)); screen \(self.isScreenVisible ? "visible" : "not visible", privacy: .public)")
        onChange?()
    }
}

extension Logger {
    static let app = Logger(subsystem: "com.claudepet.app", category: "app")
    static let session = Logger(subsystem: "com.claudepet.app", category: "session")
    static let activity = Logger(subsystem: "com.claudepet.app", category: "activity")
}
