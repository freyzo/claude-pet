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

/// The chat transcript; draws a rounded bubble behind each message tagged with `bubbleKey`.
final class TranscriptView: NSTextView {
    static let bubbleKey = NSAttributedString.Key("ClaudePetBubble")
    static let bubblePadding = NSSize(width: 10, height: 6)

    /// One per message, so neighbouring messages get separate bubbles.
    final class Bubble: NSObject {
        let fill: NSColor
        init(fill: NSColor) { self.fill = fill }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        storage.enumerateAttribute(Self.bubbleKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let bubble = value as? Bubble else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var box = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, lineGlyphs, _ in
                let visible = Self.withoutLineBreak(NSIntersectionRange(lineGlyphs, glyphs), in: layoutManager)
                guard visible.length > 0 else { return }
                let ink = layoutManager.boundingRect(forGlyphRange: visible, in: textContainer)
                box = box.union(NSRect(x: ink.minX, y: used.minY, width: ink.width, height: used.height))
            }
            guard !box.isNull else { return }
            let frame = box.offsetBy(dx: origin.x, dy: origin.y)
                .insetBy(dx: -Self.bubblePadding.width, dy: -Self.bubblePadding.height)
            guard frame.intersects(rect) else { return }
            bubble.fill.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill()
        }
    }

    /// A line's glyphs minus its trailing newline, whose box runs to the edge of the container.
    static func withoutLineBreak(_ glyphs: NSRange, in layoutManager: NSLayoutManager) -> NSRange {
        var range = glyphs
        let text = layoutManager.textStorage?.string as NSString? ?? ""
        while range.length > 0 {
            let char = text.character(at: layoutManager.characterIndexForGlyph(at: NSMaxRange(range) - 1))
            guard char == 10 || char == 13 || char == 0x2028 || char == 0x2029 else { break }
            range.length -= 1
        }
        return range
    }
}

class TerminalView: NSView, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView: NSTextView = TranscriptView(usingTextLayoutManager: false)
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
        inputLineHeight = ceil(NSLayoutManager().defaultLineHeight(for: bodyFont))
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
        textView.setAccessibilityLabel("Conversation")
        addSubview(scrollView)

        emptyStateLabel.font = bodyFont
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
        inputField.font = bodyFont
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
        sendButton.toolTip = busy ? "Stop \(assistantName)" : nil
    }

    private var assistantName = "Claude"

    func setAssistantName(_ name: String) {
        assistantName = name
        if isBusy { sendButton.toolTip = "Stop \(name)" }
    }

    /// Empties the transcript (New chat).
    func clear() {
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        currentAssistantText = ""
        scrollToBottom()
    }

    // MARK: - Transcript

    private enum Speaker { case user, pet }
    private var lastSpeaker: Speaker?
    private var petName = "Pet"
    private var petAvatar: NSImage?

    // Message text lines up under the speaker's name, right of the avatar.
    private static let textIndent: CGFloat = 28
    // Pet bubbles hug the right edge but never start left of this.
    private static let petMinLeft: CGFloat = 44
    private static let userMaxRightGap: CGFloat = 44
    private let bodyFont = TerminalView.roundedFont(13)
    private let codeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    static func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    func setPetAvatar(_ sprite: CGImage?, background: NSColor) {
        petAvatar = sprite.map { sprite in
            NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
                let circle = NSBezierPath(ovalIn: rect)
                background.setFill()
                circle.fill()
                circle.addClip()
                NSGraphicsContext.current?.cgContext.draw(sprite, in: rect.insetBy(dx: 2, dy: 2))
                return true
            }
        }
    }

    private func paragraph(extraIndent: CGFloat = 0, hanging: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 5) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = Self.textIndent + extraIndent
        p.headIndent = Self.textIndent + extraIndent + hanging
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.lineSpacing = 2
        // Bullets/numbers sit before a tab; wrapped lines align with the text, not the marker.
        if hanging > 0 { p.tabStops = [NSTextTab(textAlignment: .left, location: p.headIndent)] }
        return p
    }

    private func ensureNewline() {
        if let storage = textView.textStorage, storage.length > 0, !storage.string.hasSuffix("\n") {
            storage.append(NSAttributedString(string: "\n"))
        }
    }

    private func append(_ text: NSAttributedString) {
        textView.textStorage?.append(text)
    }

    /// Starts a message block with the speaker's avatar and name, unless they're still talking.
    private func beginTurn(_ speaker: Speaker) {
        ensureNewline()
        guard speaker != lastSpeaker else { return }
        lastSpeaker = speaker
        let t = theme
        let icon = NSTextAttachment()
        switch speaker {
        case .pet:
            icon.image = petAvatar ?? NSImage(systemSymbolName: "pawprint.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [t.accentColor]))
        case .user:
            let tint = t.textDim
            icon.image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
                tint.withAlphaComponent(0.25).setFill()
                NSBezierPath(ovalIn: rect).fill()
                let person = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [tint])))
                person?.draw(in: rect.insetBy(dx: 5, dy: 5))
                return true
            }
        }
        icon.bounds = CGRect(x: 0, y: -5, width: 20, height: 20)

        let nameFont = Self.roundedFont(13, .bold)
        let header = NSMutableAttributedString()
        let p = NSMutableParagraphStyle()
        switch speaker {
        case .pet:
            header.append(NSAttributedString(string: petName + "\u{2002}", attributes: [.font: nameFont, .foregroundColor: t.accentColor]))
            header.append(NSAttributedString(attachment: icon))
            header.append(NSAttributedString(string: "\n", attributes: [.font: nameFont]))
            p.alignment = .right
        case .user:
            header.append(NSAttributedString(attachment: icon))
            header.append(NSAttributedString(string: "\tYou\n", attributes: [.font: nameFont, .foregroundColor: t.textPrimary]))
            p.tabStops = [NSTextTab(textAlignment: .left, location: Self.textIndent)]
        }
        p.paragraphSpacingBefore = (textView.textStorage?.length ?? 0) > 0 ? 16 : 0
        p.paragraphSpacing = 2
        header.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: header.length))
        append(header)
    }

    private var transcriptWidth: CGFloat {
        let container = textView.textContainer
        let width = (container?.containerSize.width ?? 0) - 2 * (container?.lineFragmentPadding ?? 0)
        return width > 100 ? width : 360
    }

    /// Wraps one message in a bubble: the pet's on the right, yours on the left. Text inside stays left-aligned.
    private func appendBubble(_ text: NSAttributedString, from speaker: Speaker, tint: NSColor? = nil) {
        let pad = TranscriptView.bubblePadding
        let out = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: out.length)
        guard full.length > 0 else { return }
        let shift: CGFloat
        let tail: CGFloat
        switch speaker {
        case .pet:
            let right = transcriptWidth - pad.width
            let natural = naturalWidth(of: out, limit: right - Self.petMinLeft)
            shift = max(Self.petMinLeft, floor(right - natural - 1)) - Self.textIndent
            tail = -pad.width
        case .user:
            shift = pad.width - 4
            tail = -Self.userMaxRightGap
        }
        let lastParagraph = (out.string as NSString).paragraphRange(for: NSRange(location: max(0, out.length - 1), length: 0))
        out.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? paragraph()
            style.firstLineHeadIndent += shift
            style.headIndent += shift
            style.tabStops = style.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location + shift) }
            style.tailIndent = tail
            if range.location == 0 { style.paragraphSpacingBefore += pad.height + 2 }
            if NSIntersectionRange(range, lastParagraph).length > 0 { style.paragraphSpacing = max(style.paragraphSpacing, pad.height + 6) }
            out.addAttribute(.paragraphStyle, value: style, range: range)
        }
        let t = theme
        let fill = tint ?? (speaker == .pet ? t.accentColor.withAlphaComponent(0.13) : t.textPrimary.withAlphaComponent(0.07))
        out.addAttribute(TranscriptView.bubbleKey, value: TranscriptView.Bubble(fill: fill), range: full)
        append(out)
    }

    /// Width of the widest line once the message wraps inside `limit`, ignoring the default indent.
    private func naturalWidth(of text: NSAttributedString, limit: CGFloat) -> CGFloat {
        let rebased = NSMutableAttributedString(attributedString: text)
        rebased.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rebased.length)) { value, range, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.firstLineHeadIndent -= Self.textIndent
            style.headIndent -= Self.textIndent
            style.tabStops = style.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location - Self.textIndent) }
            rebased.addAttribute(.paragraphStyle, value: style, range: range)
        }
        let storage = NSTextStorage(attributedString: rebased)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: limit, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var width: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
            let visible = TranscriptView.withoutLineBreak(glyphs, in: layout)
            guard visible.length > 0 else { return }
            width = max(width, layout.boundingRect(forGlyphRange: visible, in: container).maxX)
        }
        return ceil(min(width, limit))
    }

    /// Tool steps are one quiet line each on the pet's side; hover shows the full command.
    private func appendToolRow(_ line: NSMutableAttributedString, fullText: String) {
        let p = NSMutableParagraphStyle()
        p.alignment = .right
        p.tailIndent = -TranscriptView.bubblePadding.width
        p.paragraphSpacing = 3
        let range = NSRange(location: 0, length: line.length)
        line.addAttribute(.paragraphStyle, value: p, range: range)
        if !fullText.isEmpty { line.addAttribute(.toolTip, value: fullText, range: range) }
        append(line)
    }

    private static func oneLine(_ text: String, limit: Int = 44) -> String {
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        return first.count > limit ? String(first.prefix(limit - 1)) + "…" : first
    }

    func appendUser(_ text: String) {
        beginTurn(.user)
        appendBubble(NSAttributedString(string: text + "\n", attributes: [
            .font: bodyFont, .foregroundColor: theme.textPrimary, .paragraphStyle: paragraph()
        ]), from: .user)
        scrollToBottom()
    }

    func appendStreamingText(_ text: String) {
        var cleaned = text
        if currentAssistantText.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: "^\n+", with: "", options: .regularExpression)
        }
        currentAssistantText += cleaned
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        beginTurn(.pet)
        appendBubble(renderMarkdown(cleaned), from: .pet)
        scrollToBottom()
    }

    func appendError(_ text: String) {
        beginTurn(.pet)
        appendBubble(NSAttributedString(string: text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", attributes: [
            .font: bodyFont, .foregroundColor: theme.errorColor, .paragraphStyle: paragraph()
        ]), from: .pet, tint: theme.errorColor.withAlphaComponent(0.12))
        scrollToBottom()
    }

    func appendToolUse(toolName: String, summary: String) {
        let t = theme
        beginTurn(.pet)
        let line = NSMutableAttributedString(string: toolName + "  ", attributes: [
            .font: Self.roundedFont(11, .semibold), .foregroundColor: t.accentColor
        ])
        line.append(NSAttributedString(string: Self.oneLine(summary) + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: t.textDim
        ]))
        appendToolRow(line, fullText: summary)
        scrollToBottom()
    }

    func appendToolResult(summary: String, isError: Bool) {
        let t = theme
        beginTurn(.pet)
        let line = NSMutableAttributedString(string: isError ? "✕ " : "✓ ", attributes: [
            .font: Self.roundedFont(11, .bold), .foregroundColor: isError ? t.errorColor : t.successColor
        ])
        let detail = summary.isEmpty ? (isError ? "failed" : "done") : summary
        line.append(NSAttributedString(string: Self.oneLine(detail) + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: t.textDim
        ]))
        appendToolRow(line, fullText: detail)
        scrollToBottom()
    }

    func appendNotice(_ markdown: String) {
        beginTurn(.pet)
        appendBubble(renderMarkdown(markdown), from: .pet)
        scrollToBottom()
    }

    func replayHistory(_ messages: [ClaudeSession.Message]) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        lastSpeaker = nil
        currentAssistantText = ""
        for msg in messages {
            switch msg.role {
            case .user:
                appendUser(msg.text)
            case .assistant:
                beginTurn(.pet)
                appendBubble(renderMarkdown(msg.text), from: .pet)
            case .error:
                appendError(msg.text)
            case .notice:
                appendNotice(msg.text)
            case .toolUse:
                let parts = msg.text.split(separator: ":", maxSplits: 1)
                appendToolUse(toolName: String(parts.first ?? ""),
                              summary: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
            case .toolResult:
                let isError = msg.text.hasPrefix("ERROR:")
                let summary = isError ? String(msg.text.dropFirst(6)).trimmingCharacters(in: .whitespaces) : msg.text
                appendToolResult(summary: summary, isError: isError)
            }
        }
        scrollToBottom()
    }

    private func scrollToBottom() {
        emptyStateLabel.isHidden = (textView.textStorage?.length ?? 0) > 0
        textView.scrollToEndOfDocument(nil)
    }

    func setPetName(_ name: String) {
        petName = name
        inputField.setAccessibilityLabel("Message \(name)")
        inputField.placeholder = NSAttributedString(
            string: "Ask \(name)…",
            attributes: [.font: bodyFont, .foregroundColor: theme.textDim]
        )
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "claudepet", let action = url.host else { return false }
        onAction?(action)
        return true
    }

    // MARK: - Markdown Rendering

    /// Renders one complete markdown message; always ends with a newline.
    private func renderMarkdown(_ text: String) -> NSAttributedString {
        let t = theme
        let out = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        var i = 0

        func addParagraph(_ line: NSMutableAttributedString, _ style: NSParagraphStyle) {
            line.append(NSAttributedString(string: "\n"))
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            out.append(line)
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                out.append(codeBlock(code))
                continue
            }
            if trimmed.hasPrefix("|") {
                var rows: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[i])
                    i += 1
                }
                out.append(table(rows))
                continue
            }
            i += 1
            if trimmed.isEmpty { continue }

            if let match = trimmed.firstMatch(of: #/^(#{1,6})\s+(.+)$/#) {
                let size: CGFloat = match.1.count == 1 ? 16 : match.1.count == 2 ? 15 : 13.5
                addParagraph(renderInline(String(match.2), font: Self.roundedFont(size, .bold), color: t.textPrimary),
                             paragraph(before: 6, after: 4))
            } else if trimmed.wholeMatch(of: #/(-{3,}|\*{3,}|_{3,})/#) != nil {
                addParagraph(NSMutableAttributedString(string: String(repeating: "─", count: 28), attributes: [
                    .font: bodyFont, .foregroundColor: t.separatorColor
                ]), paragraph(before: 2, after: 6))
            } else if let match = line.firstMatch(of: #/^(\s*)[-*+]\s+(.*)$/#) {
                let level = CGFloat(min(match.1.count / 2, 3))
                let item = NSMutableAttributedString(string: "•\t", attributes: [.font: bodyFont, .foregroundColor: t.accentColor])
                item.append(renderInline(String(match.2), font: bodyFont, color: t.textPrimary))
                addParagraph(item, paragraph(extraIndent: level * 14, hanging: 14, after: 3))
            } else if let match = line.firstMatch(of: #/^(\s*)(\d+)[.)]\s+(.*)$/#) {
                let level = CGFloat(min(match.1.count / 2, 3))
                let item = NSMutableAttributedString(string: "\(match.2).\t", attributes: [
                    .font: Self.roundedFont(13, .semibold), .foregroundColor: t.accentColor
                ])
                item.append(renderInline(String(match.3), font: bodyFont, color: t.textPrimary))
                addParagraph(item, paragraph(extraIndent: level * 14, hanging: 20, after: 3))
            } else if let match = trimmed.firstMatch(of: #/^>\s?(.*)$/#) {
                let quote = NSMutableAttributedString(string: "▎", attributes: [.font: bodyFont, .foregroundColor: t.separatorColor])
                quote.append(renderInline(String(match.1), font: bodyFont, color: t.textDim))
                addParagraph(quote, paragraph(extraIndent: 2, after: 3))
            } else {
                addParagraph(renderInline(trimmed, font: bodyFont, color: t.textPrimary), paragraph())
            }
        }
        return out
    }

    private func codeBlock(_ lines: [String]) -> NSAttributedString {
        let t = theme
        let out = NSMutableAttributedString()
        guard !lines.isEmpty else { return out }
        // Pad every line to the same width so the background reads as one box.
        let width = min(lines.map(\.count).max() ?? 0, 80)
        for (index, line) in lines.enumerated() {
            let padded = " " + line.padding(toLength: max(width, line.count), withPad: " ", startingAt: 0) + " "
            let p = paragraph(before: index == 0 ? 4 : 0, after: index == lines.count - 1 ? 8 : 0)
            p.lineSpacing = 1
            out.append(NSAttributedString(string: padded, attributes: [
                .font: codeFont, .foregroundColor: t.textPrimary, .backgroundColor: t.inputBg, .paragraphStyle: p
            ]))
            // Shading the newline would run the box to the edge of the view.
            out.append(NSAttributedString(string: "\n", attributes: [.font: codeFont, .paragraphStyle: p]))
        }
        return out
    }

    private func table(_ rows: [String]) -> NSAttributedString {
        let t = theme
        let out = NSMutableAttributedString()
        var cells = rows.map { row -> [String] in
            var body = row.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("|") { body.removeFirst() }
            if body.hasSuffix("|") { body.removeLast() }
            return body.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            }
        }
        let isRule: ([String]) -> Bool = { $0.allSatisfy { $0.wholeMatch(of: #/:?-{2,}:?/#) != nil } }
        let headerRow = cells.count > 1 && isRule(cells[1]) ? 0 : nil
        cells.removeAll(where: isRule)
        let columns = cells.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in
            min(cells.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0, 28)
        }
        for (index, row) in cells.enumerated() {
            let text = (0..<columns).map { column -> String in
                let cell = column < row.count ? row[column] : ""
                return cell.padding(toLength: max(widths[column], cell.count), withPad: " ", startingAt: 0)
            }.joined(separator: "  │  ")
            let isHeader = index == headerRow
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: isHeader ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold) : codeFont,
                .foregroundColor: isHeader ? t.textPrimary : t.textPrimary.withAlphaComponent(0.9),
                .paragraphStyle: paragraph(before: index == 0 ? 4 : 0, after: index == cells.count - 1 ? 8 : 2)
            ]))
            if isHeader {
                let rule = widths.map { String(repeating: "─", count: $0) }.joined(separator: "──┼──")
                out.append(NSAttributedString(string: rule + "\n", attributes: [
                    .font: codeFont, .foregroundColor: t.separatorColor, .paragraphStyle: paragraph(after: 2)
                ]))
            }
        }
        return out
    }

    private func renderInline(_ text: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let t = theme
        let result = NSMutableAttributedString()
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        var i = text.startIndex

        func plain(_ s: Substring) {
            result.append(NSAttributedString(string: String(s), attributes: [.font: font, .foregroundColor: color]))
        }

        while i < text.endIndex {
            let rest = text[i...]
            if rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
                let code = rest[rest.index(after: rest.startIndex)..<close]
                result.append(NSAttributedString(string: " \(code) ", attributes: [
                    .font: codeFont, .foregroundColor: t.accentColor, .backgroundColor: t.inputBg
                ]))
                i = text.index(after: close)
                continue
            }
            if rest.hasPrefix("**"), let close = rest.dropFirst(2).range(of: "**") {
                let inner = rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound]
                result.append(renderInline(String(inner), font: boldFont, color: color == t.textDim ? color : t.textPrimary))
                i = close.upperBound
                continue
            }
            if rest.hasPrefix("*"), let match = rest.prefixMatch(of: #/\*([^\s*][^*]*?)\*/#) {
                var attrs: [NSAttributedString.Key: Any] = [.font: italicFont, .foregroundColor: color]
                // The rounded system font has no italic face; slant it instead.
                if !italicFont.fontDescriptor.symbolicTraits.contains(.italic) { attrs[.obliqueness] = 0.18 }
                result.append(NSAttributedString(string: String(match.1), attributes: attrs))
                i = match.range.upperBound
                continue
            }
            if rest.hasPrefix("["), let match = rest.prefixMatch(of: #/\[([^\]]+)\]\(([^)\s]+)\)/#) {
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: t.accentColor]
                if let url = URL(string: String(match.2)) {
                    attrs[.link] = url
                    attrs[.cursor] = NSCursor.pointingHand
                }
                result.append(NSAttributedString(string: String(match.1), attributes: attrs))
                i = match.range.upperBound
                continue
            }
            if rest.hasPrefix("http://") || rest.hasPrefix("https://"),
               let match = rest.prefixMatch(of: #/https?:\/\/[^\s)>]+/#) {
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: t.accentColor]
                if let url = URL(string: String(match.output)) { attrs[.link] = url }
                result.append(NSAttributedString(string: String(match.output), attributes: attrs))
                i = match.range.upperBound
                continue
            }
            // Plain run up to the next character that could start markup.
            let next = rest.dropFirst().firstIndex { "`*[h".contains($0) } ?? text.endIndex
            plain(text[i..<next])
            i = next
        }
        return result
    }
}
