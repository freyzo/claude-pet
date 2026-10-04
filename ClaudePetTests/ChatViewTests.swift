import AppKit
import XCTest

final class ChatViewTests: XCTestCase {
    private var window: NSWindow!
    private var terminal: TerminalView!
    private var sent: [String] = []
    private var stops = 0

    override func setUp() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 400, height: 291), styleMask: .borderless, backing: .buffered, defer: false)
        terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 291), characterColor: TestSupport.petColor)
        window.contentView = terminal
        window.makeFirstResponder(terminal.inputField)
        sent = []
        stops = 0
        terminal.onSendMessage = { [unowned self] in sent.append($0) }
        terminal.onStop = { [unowned self] in stops += 1 }
    }

    private func pressReturn(_ modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        terminal.inputField.keyDown(with: event)
    }

    private func type(_ text: String) {
        terminal.inputField.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private var sendButton: NSButton { terminal.inputBar.subviews.compactMap { $0 as? NSButton }.first! }

    func testShiftAndOptionReturnAddLinesReturnSends() {
        type("line1")
        pressReturn(.shift)
        XCTAssertEqual(terminal.inputField.string, "line1\n")
        pressReturn(.option)
        XCTAssertEqual(terminal.inputField.string, "line1\n\n")
        XCTAssertTrue(sent.isEmpty)
        type("line2")
        pressReturn()
        XCTAssertEqual(sent, ["line1\n\nline2"])
        XCTAssertTrue(terminal.inputField.string.isEmpty)
    }

    func testInputGrowsToFiveLinesThenStopsAndShrinksAfterSend() {
        let oneLine = terminal.inputBar.frame.height
        var heights: [CGFloat] = []
        type("1")
        heights.append(terminal.inputBar.frame.height)
        for i in 2...8 {
            pressReturn(.shift)
            type("\(i)")
            heights.append(terminal.inputBar.frame.height)
        }
        for i in 0..<4 { XCTAssertGreaterThan(heights[i + 1], heights[i], "\(heights)") }
        XCTAssertTrue(heights[4...].allSatisfy { $0 == heights[4] }, "\(heights)")
        XCTAssertGreaterThan(terminal.scrollView.frame.minY, terminal.inputBar.frame.maxY)
        pressReturn()
        XCTAssertEqual(terminal.inputBar.frame.height, oneLine)
    }

    func testReturnDuringIMECompositionConfirmsInsteadOfSending() {
        terminal.inputField.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                          replacementRange: NSRange(location: NSNotFound, length: 0))
        terminal.inputField.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(terminal.inputField.hasMarkedText())
        XCTAssertEqual(terminal.inputField.string, "ni")
    }

    func testSendButtonBecomesStopWhileBusy() {
        terminal.setBusy(true)
        XCTAssertEqual(sendButton.image?.accessibilityDescription, "Stop")
        sendButton.performClick(nil)
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(sent.isEmpty)
        terminal.setBusy(false)
        XCTAssertEqual(sendButton.image?.accessibilityDescription, "Send")
    }

    func testEachSpeakerGetsOneHeaderWithAvatar() {
        terminal.setPetName("Stitch")
        terminal.setPetAvatar(TestSupport.sprite("stitch_idle"), background: .gray)
        terminal.appendUser("hi")
        terminal.appendNotice("**You're not logged in**, so I'm offline.")
        terminal.appendError("something broke")
        terminal.appendUser("again")
        terminal.appendStreamingText("answer")

        let storage = terminal.textView.textStorage!
        let text = storage.string
        var attachments = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(text.components(separatedBy: "\tStitch\n").count - 1, 2, "one pet header per pet turn")
        XCTAssertEqual(text.components(separatedBy: "\tYou\n").count - 1, 2)
        XCTAssertEqual(attachments, 4, "every header has an avatar")
        XCTAssertFalse(text.contains("**"), "markdown markers must not show")
    }

    func testMarkdownIsFormattedNotShownRaw() {
        terminal.appendStreamingText("""
        ## Title
        1. first
        - item with `code` and *slant*
        > quoted
        ```
        let x = 1
        ```
        | A | B |
        |---|---|
        | 1 | 2 |
        """)
        let text = terminal.textView.textStorage!.string
        for raw in ["## ", "```", "|---", "`code`", "*slant*", "> quoted"] {
            XCTAssertFalse(text.contains(raw), "raw markdown '\(raw)' leaked")
        }
        for shown in ["Title", "1.\tfirst", "•\titem with", "code", "slant", "quoted", "let x = 1", "A  │  B"] {
            XCTAssertTrue(text.contains(shown), "missing '\(shown)'")
        }
    }

    func testClearEmptiesTranscriptAndInputIsLabeledForVoiceOver() {
        terminal.appendUser("something")
        terminal.clear()
        XCTAssertEqual(terminal.textView.textStorage?.length, 0)
        terminal.setPetName("Stitch")
        XCTAssertEqual(terminal.inputField.accessibilityLabel(), "Message Stitch")
        XCTAssertEqual(terminal.textView.accessibilityLabel(), "Conversation")
    }
}
