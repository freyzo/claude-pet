import AppKit
import os

/// Chat engine for the GitHub Copilot CLI: one `copilot -p` process per message, one session id per conversation.
final class CopilotSession: ChatEngine {
    let provider = AIProvider.copilot
    var history: [ClaudeSession.Message] = []
    private(set) var isBusy = false
    private(set) var status: ClaudeSession.Status = .idle
    var workingDirectory = FileManager.default.homeDirectoryForCurrentUser
    var allowsEdits = true

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    var onToolUse: ((String, String) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onTurnComplete: (() -> Void)?

    /// `--session-id` starts the conversation on the first message and continues it on later ones.
    private(set) var sessionId: String?
    private var process: Process?
    private var pendingMessages: [String] = []
    private var isLocating = false
    private var lineBuffer = ""
    private var stderrText = ""
    private var replyText = ""
    private var sawResult = false
    private var exitStatus: Int32?
    private var outputEnded = false
    private var outputGeneration = 0  // output from processes we already ended is dropped

    /// Points at a specific copilot binary (custom installs, tests). Ignored unless it's executable.
    static let pathOverrideVariable = "CLAUDE_PET_COPILOT_PATH"
    private static var cachedPath: String?

    private static let notInstalledNotice = """
    **GitHub Copilot CLI isn't installed, so I'm offline.**
    [Install it](claudepet://install) (opens Terminal), then send your message again.
    """
    private static let notLoggedInNotice = """
    **You're not logged in to GitHub Copilot, so I'm offline.**
    [Log in](claudepet://login) (opens Terminal, just follow the steps), then send your message again.
    """
    private static let stoppedByUserNotice = "**Stopped.** Send a message to keep going."
    private static let crashedNotice = "**Copilot stopped unexpectedly.** Send your message again."

    // MARK: - Finding Copilot

    static func resolvePath(completion: @escaping (String?) -> Void) {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment[pathOverrideVariable], fm.isExecutableFile(atPath: override) {
            completion(override)
            return
        }
        if let cachedPath, fm.isExecutableFile(atPath: cachedPath) {
            completion(cachedPath)
            return
        }
        ClaudeSession.loadShellEnvironment {
            let home = fm.homeDirectoryForCurrentUser.path
            let shellDirs = (ClaudeSession.shellEnvironment?["PATH"] ?? "").split(separator: ":").map(String.init)
            let dirs = shellDirs + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin"]
            cachedPath = dirs.map { "\($0)/copilot" }.first { fm.isExecutableFile(atPath: $0) }
            completion(cachedPath)
        }
    }

    // MARK: - Chat

    func start() {
        guard process == nil, !isLocating, pendingMessages.isEmpty else { return }
        isLocating = true
        status = .connecting
        Self.resolvePath { [weak self] path in
            guard let self else { return }
            self.isLocating = false
            if path == nil {
                self.goOffline("Copilot CLI not installed", notice: Self.notInstalledNotice)
            } else if case .connecting = self.status {
                self.status = .ready
            }
            self.runNextIfIdle()
        }
    }

    func send(message: String) {
        history.append(.init(role: .user, text: message))
        isBusy = true
        pendingMessages.append(message)
        runNextIfIdle()
    }

    /// Ends the current answer. The next message continues the same conversation.
    func stop() {
        guard isBusy else { return }
        Logger.session.info("Copilot stopped by user")
        pendingMessages.removeAll()
        keepPartialReply()
        terminate()
        isBusy = false
        status = .idle
        notice(Self.stoppedByUserNotice)
    }

    /// Forgets the conversation; the next message starts a brand-new one.
    func reset() {
        Logger.session.info("Copilot new chat")
        terminate()
        pendingMessages.removeAll()
        history.removeAll()
        sessionId = nil
        replyText = ""
        isBusy = false
        status = .idle
    }

    func terminate() {
        outputGeneration += 1
        process?.terminate()
        process = nil
    }

    func applySettings(newConversation: Bool, notice text: String) {
        if isBusy { stop() }
        terminate()
        status = .idle
        if newConversation { sessionId = nil }
        notice(text)
    }

    func perform(action: String) -> Bool {
        switch action {
        case "login":
            let copilot = ClaudeSession.shellQuote(Self.cachedPath ?? "copilot")
            return ClaudeSession.runInTerminal(
                name: "copilot-login",
                command: "\(copilot) login",
                banner: "Log in to GitHub Copilot when asked. When you're done, close this window and send your message again."
            )
        case "install":
            let fm = FileManager.default
            let hasBrew = fm.isExecutableFile(atPath: "/opt/homebrew/bin/brew") || fm.isExecutableFile(atPath: "/usr/local/bin/brew")
            return ClaudeSession.runInTerminal(
                name: "copilot-install",
                command: hasBrew ? "brew install --cask copilot-cli" : "npm install -g @github/copilot",
                banner: "Installing GitHub Copilot CLI. When it finishes, close this window and send your message again."
            )
        default:
            return false
        }
    }

    // MARK: - Process

    private func runNextIfIdle() {
        guard process == nil, !isLocating, !pendingMessages.isEmpty else { return }
        isLocating = true
        Self.resolvePath { [weak self] path in
            guard let self else { return }
            self.isLocating = false
            // Stop or New chat may have emptied the queue while Copilot was being located.
            guard !self.pendingMessages.isEmpty else { return }
            guard let path else {
                self.goOffline("Copilot CLI not installed", notice: Self.notInstalledNotice)
                return
            }
            self.launch(path: path, message: self.pendingMessages.removeFirst())
        }
    }

    private func launch(path: String, message: String) {
        let id = sessionId ?? UUID().uuidString.lowercased()
        sessionId = id
        var arguments = ["-p", message, "--output-format", "json", "--stream", "on", "-s", "--session-id", id,
                         "--allow-all-tools"]
        // Without a terminal Copilot needs --allow-all-tools; "edits off" then blocks the tools that change things.
        if !allowsEdits { arguments += ["--deny-tool", "shell", "--deny-tool", "write"] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            proc.currentDirectoryURL = workingDirectory
        } else {
            notice("**Can't find the folder \(ClaudeSession.displayPath(workingDirectory)),** so Copilot is working in your home folder. Pick another one from the menu bar icon → Assistant.")
            proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        var env = ClaudeSession.shellEnvironment ?? ProcessInfo.processInfo.environment
        let toolDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        env["PATH"] = [toolDir, env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        lineBuffer = ""
        stderrText = ""
        sawResult = false
        exitStatus = nil
        outputEnded = false
        outputGeneration += 1
        let generation = outputGeneration

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                DispatchQueue.main.async {
                    guard let self, self.outputGeneration == generation else { return }
                    self.outputEnded = true
                    self.finishIfDone()
                }
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.outputGeneration == generation else { return }
                self.processOutput(text)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.outputGeneration == generation else { return }
                self.stderrText += text
            }
        }
        proc.terminationHandler = { [weak self] exited in
            DispatchQueue.main.async {
                guard let self, self.process === exited else { return }
                self.exitStatus = exited.terminationStatus
                self.finishIfDone()
                // A helper process can keep the output pipe open; don't wait on it forever.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard self.process === exited, !self.outputEnded else { return }
                    self.outputEnded = true
                    self.finishIfDone()
                }
            }
        }

        do {
            try proc.run()
            process = proc
            if case .offline = status {} else { status = .ready }
            Logger.session.info("Copilot started (pid \(proc.processIdentifier, privacy: .public), edits \(self.allowsEdits ? "on" : "off", privacy: .public))")
        } catch {
            goOffline("couldn't start", notice: """
            **Couldn't start GitHub Copilot CLI, so I'm offline.** (\(error.localizedDescription))
            [Reinstall it](claudepet://install), then send your message again.
            """)
        }
    }

    /// A turn is over once the process has exited and all of its output has been read.
    private func finishIfDone() {
        guard let status = exitStatus, outputEnded, process != nil else { return }
        processEnded(status: status)
    }

    private func processEnded(status exitStatus: Int32) {
        process = nil
        if !lineBuffer.isEmpty { parseLine(lineBuffer); lineBuffer = "" }
        if sawResult {
            runNextIfIdle()
            return
        }
        keepPartialReply()
        if Self.isLoginProblem(stderrText) {
            goOffline("not logged in", notice: Self.notLoggedInNotice)
            return
        }
        Logger.session.error("Copilot exited without an answer (status \(exitStatus, privacy: .public))")
        let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty {
            let shortDetail = String(detail.prefix(300))
            history.append(.init(role: .error, text: shortDetail))
            onError?(shortDetail)
        }
        pendingMessages.removeAll()
        isBusy = false
        self.status = .idle
        notice(Self.crashedNotice)
    }

    private static func isLoginProblem(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["not logged in", "copilot login", "no authentication", "not authenticated", "unauthorized", "please log in"]
            .contains { lower.contains($0) }
    }

    // MARK: - JSONL events

    private func processOutput(_ text: String) {
        lineBuffer += text
        while let newline = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newline])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
            if !line.isEmpty { parseLine(line) }
        }
    }

    private func parseLine(_ line: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = json["type"] as? String else { return }
        let data = json["data"] as? [String: Any] ?? [:]

        switch type {
        case "assistant.message":
            let content = (data["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }
            replyText += (replyText.isEmpty ? "" : "\n\n") + content
            onText?(content)

        case "tool.execution_start":
            let name = Self.toolTitle(data["toolName"] as? String ?? "tool")
            let arguments = data["arguments"] as? [String: Any] ?? [:]
            let summary = ["command", "path", "pattern", "url", "description"].lazy
                .compactMap { arguments[$0] as? String }.first ?? ""
            history.append(.init(role: .toolUse, text: "\(name): \(summary)"))
            onToolUse?(name, summary)

        case "tool.execution_complete":
            let succeeded = data["success"] as? Bool ?? false
            let content = (data["result"] as? [String: Any])?["content"] as? String ?? ""
            var summary = content.split(separator: "\n").map(String.init)
                .first { !$0.hasPrefix("<shellId") && !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            summary = String(summary.prefix(80))
            if !succeeded && summary.isEmpty { summary = "blocked or failed" }
            history.append(.init(role: .toolResult, text: succeeded ? summary : "ERROR: \(summary)"))
            onToolResult?(summary, !succeeded)

        case "result":
            sawResult = true
            if let id = json["sessionId"] as? String { sessionId = id }
            if !replyText.isEmpty { history.append(.init(role: .assistant, text: replyText)) }
            replyText = ""
            status = .ready
            isBusy = !pendingMessages.isEmpty
            onTurnComplete?()

        default:
            break
        }
    }

    private static func toolTitle(_ raw: String) -> String {
        switch raw {
        case "bash", "shell": return "Bash"
        case "create", "edit", "str_replace", "write": return "Edit"
        case "view", "read": return "Read"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    // MARK: - Helpers

    private func keepPartialReply() {
        guard !replyText.isEmpty else { return }
        history.append(.init(role: .assistant, text: replyText))
        replyText = ""
    }

    private func goOffline(_ reason: String, notice text: String) {
        Logger.session.notice("Copilot offline: \(reason, privacy: .public)")
        status = .offline(reason)
        isBusy = false
        pendingMessages.removeAll()
        notice(text)
    }

    private func notice(_ text: String) {
        guard history.last?.text != text else { return }
        history.append(.init(role: .notice, text: text))
        onNotice?(text)
    }
}
