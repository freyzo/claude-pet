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
}
