import AppKit

/// Chat input: Return sends, Shift+Return or Option+Return starts a new line.
final class ChatInputView: NSTextView {
    var onSubmit: (() -> Void)?
    var placeholder: NSAttributedString? { didSet { needsDisplay = true } }
    private var newlineModifierHeld = false

    override func keyDown(with event: NSEvent) {
        newlineModifierHeld = !event.modifierFlags.intersection([.shift, .option]).isEmpty
        super.keyDown(with: event)
        newlineModifierHeld = false
    }

    // Return while composing (Chinese/Japanese input) only confirms the composition, never sends.
    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) && hasMarkedText() {
            unmarkText()
            return
        }
        if selector == #selector(insertNewline(_:)) && !newlineModifierHeld {
            onSubmit?()
            return
        }
        super.doCommand(by: selector)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true  // show/hide the placeholder
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder else { return }
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        placeholder.draw(at: NSPoint(x: x, y: textContainerOrigin.y))
    }
}

class TerminalView: NSView, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView = NSTextView()
    let inputBar = NSView()
    private let inputScroll = NSScrollView()
    let inputField = ChatInputView(frame: .zero)
    private let sendButton = NSButton()
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "Ask me anything.\nI can read files, run commands and write code.")
    var onSendMessage: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onAction: ((String) -> Void)?  // host of a clicked claudepet:// link

    private var currentAssistantText = ""
    private let characterColor: NSColor?
    private var isBusy = false

    // Input geometry: the pill grows with the text up to maxInputLines, then scrolls.
    private static let padding: CGFloat = 14
    private static let inputBottom: CGFloat = 12
    private static let barInset: CGFloat = 6
    private static let textInset = NSSize(width: 2, height: 3)
    private static let maxInputLines: CGFloat = 5
    private var inputLineHeight: CGFloat = 16

    init(frame: NSRect, characterColor: NSColor?) {
        self.characterColor = characterColor
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        characterColor = nil
        super.init(coder: coder)
        setupViews()
    }

    var theme: PopoverTheme {
        var t = PopoverTheme.current
        if let color = characterColor { t = t.withCharacterColor(color) }
        t = t.withCustomFont()
        return t
    }

    // MARK: - Setup

    private func setupViews() {
        let t = theme
        let padding = Self.padding
        inputLineHeight = ceil(NSLayoutManager().defaultLineHeight(for: t.font))
        let inputHeight = inputLineHeight + Self.textInset.height * 2 + Self.barInset * 2
        let inputBottom = Self.inputBottom

        scrollView.frame = NSRect(
            x: padding - 4, y: inputBottom + inputHeight + 8,
            width: frame.width - (padding - 4) * 2,
            height: frame.height - inputBottom - inputHeight - 14
        )
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        textView.frame = scrollView.contentView.bounds
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textColor = t.textPrimary
        textView.font = t.font
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 6, height: 10)
        let defaultPara = NSMutableParagraphStyle()
        defaultPara.paragraphSpacing = 8
        textView.defaultParagraphStyle = defaultPara
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.delegate = self
        textView.linkTextAttributes = [
            .foregroundColor: t.accentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        scrollView.documentView = textView
        addSubview(scrollView)

        emptyStateLabel.font = t.font
        emptyStateLabel.textColor = t.textDim
        emptyStateLabel.alignment = .center
        emptyStateLabel.frame = NSRect(x: padding + 20, y: scrollView.frame.midY - 20, width: frame.width - (padding + 20) * 2, height: 40)
        emptyStateLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(emptyStateLabel)

        let barWidth = frame.width - padding * 2
        inputBar.frame = NSRect(x: padding, y: inputBottom, width: barWidth, height: inputHeight)
        inputBar.autoresizingMask = [.width]
        inputBar.wantsLayer = true
        inputBar.layer?.backgroundColor = t.inputBg.cgColor
        inputBar.layer?.cornerRadius = min(inputHeight / 2, 17)
        inputBar.layer?.borderWidth = 1
        inputBar.layer?.borderColor = t.separatorColor.cgColor
        addSubview(inputBar)

        inputScroll.drawsBackground = false
        inputScroll.borderType = .noBorder
        inputScroll.hasVerticalScroller = false
        inputScroll.hasHorizontalScroller = false
        inputScroll.autoresizingMask = [.width]
        inputBar.addSubview(inputScroll)

        inputField.isRichText = false
        inputField.importsGraphics = false
        inputField.allowsUndo = true
        inputField.drawsBackground = false
        inputField.font = t.font
        inputField.textColor = t.textPrimary
        inputField.insertionPointColor = t.textPrimary
        inputField.textContainerInset = Self.textInset
        // Code and commands get typed here: keep quotes and dashes exactly as typed.
        inputField.isAutomaticQuoteSubstitutionEnabled = false
        inputField.isAutomaticDashSubstitutionEnabled = false
        inputField.isAutomaticTextReplacementEnabled = false
        inputField.isVerticallyResizable = true
        inputField.isHorizontallyResizable = false
        inputField.autoresizingMask = [.width]
        inputField.textContainer?.widthTracksTextView = true
        inputField.delegate = self
        inputField.onSubmit = { [weak self] in self?.submitInput() }
        inputScroll.documentView = inputField

        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")
        sendButton.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        sendButton.imagePosition = .imageOnly
        sendButton.isBordered = false
        sendButton.contentTintColor = t.accentColor
        sendButton.frame = NSRect(x: barWidth - 32, y: (inputHeight - 28) / 2, width: 28, height: 28)
        sendButton.autoresizingMask = [.minXMargin]
        sendButton.target = self
        sendButton.action = #selector(sendButtonClicked)
        inputBar.addSubview(sendButton)

        layoutInput()
    }

    // MARK: - Input

    func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === inputField else { return }
        layoutInput()
    }

    /// Sizes the input to its text (1...maxInputLines lines) and gives the rest to the transcript.
    func layoutInput() {
        guard let layoutManager = inputField.layoutManager, let container = inputField.textContainer else { return }
        let barWidth = bounds.width - Self.padding * 2
        let fieldWidth = barWidth - Self.barInset - 2 - 34
        if inputField.frame.width != fieldWidth {
            inputField.frame.size.width = fieldWidth
        }
        layoutManager.ensureLayout(for: container)
        let textHeight = ceil(layoutManager.usedRect(for: container).height)
        let visibleText = min(max(textHeight, inputLineHeight), inputLineHeight * Self.maxInputLines)
        let fieldHeight = visibleText + Self.textInset.height * 2
        let barHeight = fieldHeight + Self.barInset * 2
        let oldBarHeight = inputBar.frame.height

        inputBar.frame = NSRect(x: Self.padding, y: Self.inputBottom, width: barWidth, height: barHeight)
        inputScroll.frame = NSRect(x: Self.barInset + 2, y: Self.barInset, width: fieldWidth, height: fieldHeight)
        inputField.minSize = NSSize(width: 0, height: fieldHeight)
        inputField.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        inputField.sizeToFit()
        let transcriptY = Self.inputBottom + barHeight + 8
        scrollView.frame = NSRect(
            x: Self.padding - 4, y: transcriptY,
            width: bounds.width - (Self.padding - 4) * 2,
            height: max(bounds.height - transcriptY - 6, 0)
        )
        inputField.scrollRangeToVisible(inputField.selectedRange())
        if barHeight != oldBarHeight { textView.scrollToEndOfDocument(nil) }
    }

    @objc private func sendButtonClicked() {
        if isBusy { onStop?() } else { submitInput() }
    }

    private func submitInput() {
        let text = inputField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.string = ""
        layoutInput()

        appendUser(text)
        currentAssistantText = ""
        onSendMessage?(text)
    }

    /// While Claude is answering the send button becomes Stop. Return still sends (queued).
    func setBusy(_ busy: Bool) {
        guard busy != isBusy else { return }
        isBusy = busy
        sendButton.image = NSImage(
            systemSymbolName: busy ? "stop.circle.fill" : "arrow.up.circle.fill",
            accessibilityDescription: busy ? "Stop" : "Send"
        )
        sendButton.toolTip = busy ? "Stop Claude" : nil
    }

    /// Empties the transcript (New chat).
    func clear() {
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        currentAssistantText = ""
        scrollToBottom()
    }

    // MARK: - Append Methods

    private var messageSpacing: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 8
        return p
    }

    private func ensureNewline() {
        if let storage = textView.textStorage, storage.length > 0 {
            if !storage.string.hasSuffix("\n") {
                storage.append(NSAttributedString(string: "\n"))
            }
        }
    }

    func appendUser(_ text: String) {
        let t = theme
        ensureNewline()
        let para = messageSpacing
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: "> ", attributes: [
            .font: t.fontBold, .foregroundColor: t.accentColor, .paragraphStyle: para
        ]))
        attributed.append(NSAttributedString(string: "\(text)\n", attributes: [
            .font: t.fontBold, .foregroundColor: t.textPrimary, .paragraphStyle: para
        ]))
        textView.textStorage?.append(attributed)
        scrollToBottom()
    }

    func appendStreamingText(_ text: String) {
        var cleaned = text
        if currentAssistantText.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: "^\n+", with: "", options: .regularExpression)
        }
        currentAssistantText += cleaned
        if !cleaned.isEmpty {
            textView.textStorage?.append(renderMarkdown(cleaned))
            scrollToBottom()
        }
    }

    func appendError(_ text: String) {
        let t = theme
        textView.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [
            .font: t.font, .foregroundColor: t.errorColor
        ]))
        scrollToBottom()
    }

    func appendToolUse(toolName: String, summary: String) {
        let t = theme
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: "  \(toolName.uppercased()) ", attributes: [
            .font: t.fontBold, .foregroundColor: t.accentColor
        ]))
        block.append(NSAttributedString(string: "\(summary)\n", attributes: [
            .font: t.font, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func appendToolResult(summary: String, isError: Bool) {
        let t = theme
        let color = isError ? t.errorColor : t.successColor
        let prefix = isError ? "  FAIL " : "  DONE "
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: prefix, attributes: [
            .font: t.fontBold, .foregroundColor: color
        ]))
        block.append(NSAttributedString(string: "\(summary)\n", attributes: [
            .font: t.font, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func replayHistory(_ messages: [ClaudeSession.Message]) {
        let t = theme
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        for msg in messages {
            switch msg.role {
            case .user:
                appendUser(msg.text)
            case .assistant:
                textView.textStorage?.append(renderMarkdown(msg.text + "\n"))
            case .error:
                appendError(msg.text)
            case .notice:
                ensureNewline()
                textView.textStorage?.append(renderMarkdown(msg.text + "\n"))
            case .toolUse:
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: t.font, .foregroundColor: t.accentColor
                ]))
            case .toolResult:
                let isErr = msg.text.hasPrefix("ERROR:")
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: t.font, .foregroundColor: isErr ? t.errorColor : t.successColor
                ]))
            }
        }
        scrollToBottom()
    }

    private func scrollToBottom() {
        emptyStateLabel.isHidden = (textView.textStorage?.length ?? 0) > 0
        textView.scrollToEndOfDocument(nil)
    }

    func appendNotice(_ markdown: String) {
        ensureNewline()
        textView.textStorage?.append(renderMarkdown(markdown + "\n"))
        scrollToBottom()
    }

    func setPetName(_ name: String) {
        let t = theme
        inputField.placeholder = NSAttributedString(
            string: "Ask \(name)…",
            attributes: [.font: t.font, .foregroundColor: t.textDim]
        )
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "claudepet", let action = url.host else { return false }
        onAction?(action)
        return true
    }

    // MARK: - Markdown Rendering

    private func renderMarkdown(_ text: String) -> NSAttributedString {
        let t = theme
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeLines: [String] = []

        for (i, line) in lines.enumerated() {
            let suffix = i < lines.count - 1 ? "\n" : ""

            if line.hasPrefix("```") {
                if inCodeBlock {
                    let codeText = codeLines.joined(separator: "\n")
                    let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 1, weight: .regular)
                    result.append(NSAttributedString(string: codeText + "\n", attributes: [
                        .font: codeFont, .foregroundColor: t.textPrimary, .backgroundColor: t.inputBg
                    ]))
                    inCodeBlock = false
                    codeLines = []
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            if line.hasPrefix("### ") {
                result.append(NSAttributedString(string: String(line.dropFirst(4)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("## ") {
                result.append(NSAttributedString(string: String(line.dropFirst(3)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize + 1, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("# ") {
                result.append(NSAttributedString(string: String(line.dropFirst(2)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize + 2, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let content = String(line.dropFirst(2))
                result.append(NSAttributedString(string: "  \u{2022} ", attributes: [
                    .font: t.font, .foregroundColor: t.accentColor
                ]))
                result.append(renderInlineMarkdown(content + suffix, theme: t))
            } else {
                result.append(renderInlineMarkdown(line + suffix, theme: t))
            }
        }

        if inCodeBlock && !codeLines.isEmpty {
            let codeText = codeLines.joined(separator: "\n")
            let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 1, weight: .regular)
            result.append(NSAttributedString(string: codeText + "\n", attributes: [
                .font: codeFont, .foregroundColor: t.textPrimary, .backgroundColor: t.inputBg
            ]))
        }

        return result
    }

    private func renderInlineMarkdown(_ text: String, theme t: PopoverTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var i = text.startIndex

        while i < text.endIndex {
            if text[i] == "`" {
                let afterTick = text.index(after: i)
                if afterTick < text.endIndex, let closeIdx = text[afterTick...].firstIndex(of: "`") {
                    let code = String(text[afterTick..<closeIdx])
                    let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 0.5, weight: .regular)
                    result.append(NSAttributedString(string: code, attributes: [
                        .font: codeFont, .foregroundColor: t.accentColor, .backgroundColor: t.inputBg
                    ]))
                    i = text.index(after: closeIdx)
                    continue
                }
            }
            if text[i] == "*",
               text.index(after: i) < text.endIndex, text[text.index(after: i)] == "*" {
                let start = text.index(i, offsetBy: 2)
                if start < text.endIndex, let range = text.range(of: "**", range: start..<text.endIndex) {
                    let bold = String(text[start..<range.lowerBound])
                    result.append(NSAttributedString(string: bold, attributes: [
                        .font: t.fontBold, .foregroundColor: t.textPrimary
                    ]))
                    i = range.upperBound
                    continue
                }
            }
            if text[i] == "[" {
                let afterBracket = text.index(after: i)
                if afterBracket < text.endIndex,
                   let closeBracket = text[afterBracket...].firstIndex(of: "]") {
                    let parenStart = text.index(after: closeBracket)
                    if parenStart < text.endIndex && text[parenStart] == "(" {
                        let afterParen = text.index(after: parenStart)
                        if afterParen < text.endIndex,
                           let closeParen = text[afterParen...].firstIndex(of: ")") {
                            let linkText = String(text[afterBracket..<closeBracket])
                            let urlStr = String(text[afterParen..<closeParen])
                            var attrs: [NSAttributedString.Key: Any] = [
                                .font: t.font,
                                .foregroundColor: t.accentColor,
                                .underlineStyle: NSUnderlineStyle.single.rawValue
                            ]
                            if let url = URL(string: urlStr) {
                                attrs[.link] = url
                                attrs[.cursor] = NSCursor.pointingHand
                            }
                            result.append(NSAttributedString(string: linkText, attributes: attrs))
                            i = text.index(after: closeParen)
                            continue
                        }
                    }
                }
            }
            if text[i] == "h" {
                let remaining = String(text[i...])
                if remaining.hasPrefix("https://") || remaining.hasPrefix("http://") {
                    var j = i
                    while j < text.endIndex && !text[j].isWhitespace && text[j] != ")" && text[j] != ">" {
                        j = text.index(after: j)
                    }
                    let urlStr = String(text[i..<j])
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: t.font,
                        .foregroundColor: t.accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                    if let url = URL(string: urlStr) {
                        attrs[.link] = url
                    }
                    result.append(NSAttributedString(string: urlStr, attributes: attrs))
                    i = j
                    continue
                }
            }
            result.append(NSAttributedString(string: String(text[i]), attributes: [
                .font: t.font, .foregroundColor: t.textPrimary
            ]))
            i = text.index(after: i)
        }
        return result
    }
}
