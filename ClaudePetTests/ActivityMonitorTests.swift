import AppKit
import XCTest

final class ActivityMonitorTests: XCTestCase {
    private var workspace: NotificationCenter!
    private var distributed: NotificationCenter!
    private var process: NotificationCenter!
    private var reduceMotion = false
    private var lowPower = false
    private var hot = false
    private var monitor: PetActivityMonitor!
    private var changes = 0

    override func setUp() {
        workspace = NotificationCenter()
        distributed = NotificationCenter()
        process = NotificationCenter()
        reduceMotion = false
        lowPower = false
        hot = false
        changes = 0
        monitor = PetActivityMonitor(
            workspaceCenter: workspace, distributedCenter: distributed, processCenter: process,
            reduceMotion: { [unowned self] in reduceMotion },
            lowPower: { [unowned self] in lowPower },
            hot: { [unowned self] in hot }
        )
        monitor.onChange = { [unowned self] in changes += 1 }
    }

    private func post(_ center: NotificationCenter, _ name: Notification.Name) {
        center.post(name: name, object: nil)
        TestSupport.spin(0.05)
    }

    func testStartsActiveAndVisible() {
        XCTAssertFalse(monitor.isCalm)
        XCTAssertTrue(monitor.isScreenVisible)
    }

    func testReduceMotionLowPowerAndHeatEachCalmThePets() {
        reduceMotion = true
        post(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        XCTAssertEqual(monitor.calmReason, .reduceMotion)
        reduceMotion = false
        post(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        XCTAssertNil(monitor.calmReason)

        lowPower = true
        post(process, .NSProcessInfoPowerStateDidChange)
        XCTAssertEqual(monitor.calmReason, .lowPower)
        lowPower = false
        post(process, .NSProcessInfoPowerStateDidChange)

        hot = true
        post(process, ProcessInfo.thermalStateDidChangeNotification)
        XCTAssertEqual(monitor.calmReason, .hot)
        hot = false
        post(process, ProcessInfo.thermalStateDidChangeNotification)
        XCTAssertFalse(monitor.isCalm)
        XCTAssertEqual(changes, 6)
    }

    func testOverlappingReasonsKeepPetsCalmUntilAllClear() {
        monitor.userPaused = true
        lowPower = true
        post(process, .NSProcessInfoPowerStateDidChange)
        monitor.userPaused = false
        XCTAssertEqual(monitor.calmReason, .lowPower, "unpausing must not wake pets while Low Power Mode is on")
        lowPower = false
        post(process, .NSProcessInfoPowerStateDidChange)
        XCTAssertFalse(monitor.isCalm)
    }

    func testScreenNotVisibleWhileAsleepLockedScreensaverOrUserSwitched() {
        let pairs: [(NotificationCenter, Notification.Name, Notification.Name)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            (distributed, PetActivityMonitor.screenLocked, PetActivityMonitor.screenUnlocked),
            (distributed, PetActivityMonitor.screenSaverStarted, PetActivityMonitor.screenSaverStopped),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)
        ]
        for (center, hide, show) in pairs {
            post(center, hide)
            XCTAssertFalse(monitor.isScreenVisible, "\(hide.rawValue)")
            post(center, show)
            XCTAssertTrue(monitor.isScreenVisible, "\(show.rawValue)")
        }
    }

    func testLockedAndAsleepTogetherNeedBothCleared() {
        post(distributed, PetActivityMonitor.screenLocked)
        post(workspace, NSWorkspace.screensDidSleepNotification)
        post(workspace, NSWorkspace.screensDidWakeNotification)
        XCTAssertFalse(monitor.isScreenVisible, "still locked")
        post(distributed, PetActivityMonitor.screenUnlocked)
        XCTAssertTrue(monitor.isScreenVisible)
    }

    func testBackgroundThreadNotificationsAreHandledOnMain() {
        var calledOnMain: Bool?
        monitor.onChange = { calledOnMain = Thread.isMainThread }
        lowPower = true
        let center = process!
        DispatchQueue.global().async { center.post(name: .NSProcessInfoPowerStateDidChange, object: nil) }
        XCTAssertTrue(TestSupport.wait(5) { calledOnMain != nil })
        XCTAssertEqual(calledOnMain, true)
    }

    func testUnchangedSignalsDontNotify() {
        post(process, .NSProcessInfoPowerStateDidChange)
        post(workspace, NSWorkspace.screensDidWakeNotification)
        XCTAssertEqual(changes, 0)
    }
}
