import AppKit
import XCTest

final class PetTests: XCTestCase {
    override func setUp() {
        _ = NSApplication.shared
    }

    private func newChatButton(_ pet: WalkerCharacter) -> NSButton? {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.image?.accessibilityDescription == "New Chat" { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return pet.popoverWindow?.contentView.flatMap(find)
    }

    private func roamingPet() -> WalkerCharacter {
        let pet = TestSupport.makePet()
        pet.isPaused = true
        pet.pauseEndTime = 0
        // The real mouse is system-wide; clicks made while tests run must not count.
        pet.mouseButtonsDown = { false }
        return pet
    }

    func testNewChatButtonHiddenInOnboardingDisabledWhenEmptyAndClears() {
        let pet = TestSupport.makePet()
        pet.isOnboarding = true
        pet.createPopoverWindow()
        XCTAssertEqual(newChatButton(pet)?.isHidden, true)

        pet.isOnboarding = false
        let session = ClaudeSession()
        pet.claudeSession = session
        pet.createPopoverWindow()
        XCTAssertEqual(newChatButton(pet)?.isEnabled, false, "nothing to clear yet")

        session.history.append(.init(role: .user, text: "hi"))
        pet.createPopoverWindow()
        pet.terminalView?.appendUser("hi")
        XCTAssertEqual(newChatButton(pet)?.isEnabled, true)
        newChatButton(pet)?.performClick(nil)
        XCTAssertTrue(session.history.isEmpty)
        XCTAssertEqual(pet.terminalView?.textView.textStorage?.length, 0)
    }

    func testDoneBubbleSurvivesWhileChatIsOpenAtLowTickRate() {
        let pet = TestSupport.makePet()
        pet.isIdleForPopover = true
        pet.showingCompletion = true
        pet.completionBubbleExpiry = CACurrentMediaTime() + 0.2
        for _ in 0..<6 {
            pet.updateThinkingBubble()
            TestSupport.spin(0.1)
        }
        XCTAssertTrue(pet.showingCompletion)
    }

    func testCalmPetNeverStartsWalkingButNormalPetDoes() {
        let calm = roamingPet()
        calm.isCalm = true
        for _ in 0..<20 { calm.update() }
        XCTAssertFalse(calm.isWalking)

        let normal = roamingPet()
        normal.update()
        XCTAssertTrue(normal.isWalking)
    }

    func testBecomingCalmMidWalkSettlesTheFeetOnTheGround() {
        let pet = roamingPet()
        pet.update()
        XCTAssertTrue(pet.isWalking)
        let groundY = pet.positionY
        pet.isCalm = true
        XCTAssertFalse(pet.isWalking)
        XCTAssertTrue(pet.isPaused)
        pet.update()
        guard let screen = NSScreen.main else { return }
        let expectedY = screen.frame.minY + screen.frame.height * groundY
        XCTAssertEqual(pet.window.frame.origin.y, expectedY, accuracy: 0.5, "pet left hanging mid-hop")
    }

    func testCalmPetStillReactsToClicks() {
        let pet = roamingPet()
        pet.isCalm = true
        pet.isOnboarding = true
        pet.handleClick()
        XCTAssertTrue(pet.isIdleForPopover)
    }

    func testPetIsAVoiceOverButtonNamedAfterThePet() {
        let pet = TestSupport.makePet()
        pet.name = "Stitch"
        pet.isOnboarding = true  // pressing opens the welcome, no Claude process
        let view = CharacterContentView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
        view.character = pet
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .button)
        XCTAssertEqual(view.accessibilityLabel(), "Stitch")
        XCTAssertNotNil(view.accessibilityHelp())
        pet.rename(to: "Bubbles")
        XCTAssertEqual(view.accessibilityLabel(), "Bubbles")
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertTrue(pet.isIdleForPopover)
    }

    func testRightClickOnPetShowsTheAppMenu() {
        let controller = ClaudePetController()
        let menu = NSMenu(title: "app")
        controller.contextMenuProvider = { menu }
        let pet = TestSupport.makePet()
        pet.controller = controller
        let view = CharacterContentView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
        view.character = pet
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 80, y: 80), modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        XCTAssertTrue(view.menu(for: event) === menu)
    }

    func testChatFromMenuOpensButNeverTogglesClosed() {
        let pet = TestSupport.makePet()
        pet.isOnboarding = true
        pet.openChatFromMenu()
        XCTAssertTrue(pet.isIdleForPopover)
        pet.openChatFromMenu()
        XCTAssertTrue(pet.isIdleForPopover, "second menu pick must not close the chat")
    }

    // MARK: - Staying out of the way

    private func run(_ pet: WalkerCharacter, for seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            pet.update()
            TestSupport.spin(1.0 / 30)
        }
    }

    private func body(_ pet: WalkerCharacter) -> NSRect {
        pet.window.frame.insetBy(dx: 160 * 0.18, dy: 160 * 0.12)
    }

    /// A calm pet (won't wander on its own) with the cursor parked on its belly.
    private func petUnderCursor() -> (WalkerCharacter, NSPoint) {
        let pet = roamingPet()
        pet.isCalm = true
        pet.cursorLocation = { NSPoint(x: -99_999, y: -99_999) }
        pet.update()
        let cursor = NSPoint(x: pet.window.frame.midX, y: pet.window.frame.midY)
        pet.cursorLocation = { cursor }
        return (pet, cursor)
    }

    func testPetMovesOutFromUnderARestingCursorAfterASecond() {
        let (pet, cursor) = petUnderCursor()
        run(pet, for: 0.6)
        XCTAssertFalse(pet.isWalking, "too early: you may still be about to click it")
        run(pet, for: 0.7)
        XCTAssertTrue(pet.isWalking, "should be getting out of the way")
        XCTAssertTrue(TestSupport.wait(6) { pet.update(); return !pet.isWalking })
        XCTAssertFalse(body(pet).contains(cursor), "pet ended up under the cursor again")
        run(pet, for: 1.5)
        XCTAssertFalse(body(pet).contains(cursor))
    }

    func testNoDodgeWhileMouseButtonIsHeld() {
        let (pet, _) = petUnderCursor()
        pet.mouseButtonsDown = { true }
        run(pet, for: 1.5)
        XCTAssertFalse(pet.isWalking)
    }

    func testDroppedPetStaysWhereYouPutItUntilCursorLeaves() {
        let (pet, cursor) = petUnderCursor()
        pet.isBeingDragged = true
        pet.finishDrag()
        run(pet, for: 1.5)
        XCTAssertFalse(pet.isWalking, "just dropped there on purpose")
        pet.cursorLocation = { NSPoint(x: -99_999, y: -99_999) }
        run(pet, for: 0.1)
        pet.cursorLocation = { cursor }
        run(pet, for: 1.3)
        XCTAssertTrue(pet.isWalking, "cursor came back and rested: now it moves")
    }

    func testCornerPetWalksToCornerStaysAndDodgesToTheOtherCorner() {
        let pet = roamingPet()
        pet.cursorLocation = { NSPoint(x: -99_999, y: -99_999) }
        pet.update()
        pet.goToCorner(onRight: true)
        XCTAssertTrue(pet.isParked)
        XCTAssertTrue(pet.isWalking, "walks there")
        XCTAssertTrue(TestSupport.wait(8) { pet.update(); return !pet.isWalking })
        guard let screen = NSScreen.main else { return }
        XCTAssertEqual(pet.window.frame.maxX, screen.visibleFrame.maxX - 12, accuracy: 1)
        XCTAssertEqual(pet.window.frame.minY, screen.visibleFrame.minY, accuracy: 1)

        pet.pauseEndTime = 0
        run(pet, for: 1.0)
        XCTAssertFalse(pet.isWalking, "a parked pet never wanders off")

        let cursor = NSPoint(x: pet.window.frame.midX, y: pet.window.frame.midY)
        pet.cursorLocation = { cursor }
        run(pet, for: 1.3)
        XCTAssertTrue(pet.isWalking)
        XCTAssertFalse(pet.parkedOnRight, "moves to the other corner")
        XCTAssertTrue(pet.isParked)
        XCTAssertTrue(TestSupport.wait(10) { pet.update(); return !pet.isWalking })
        XCTAssertEqual(pet.window.frame.minX, screen.visibleFrame.minX + 12, accuracy: 1)

        pet.leaveCorner()
        XCTAssertFalse(pet.isParked)
    }
}
