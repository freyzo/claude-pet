import AppKit
import os

class ClaudeSession {
    enum Status: Equatable {
        case idle
        case connecting
        case ready
        case offline(String)  // short reason shown in the chat header
    }

    private var process: Process?
    private var inputPipe: Pipe?
    private var lineBuffer = ""
    private var outputGeneration = 0  // bumps on every launch/terminate; older output is dropped
    private(set) var isRunning = false
    private(set) var isBusy = false  // true between send() and result
    private(set) var status: Status = .idle
    private var isStarting = false
    private var needsLogin = false
    private var pendingMessages: [String] = []
    private static var claudePath: String?
    /// The user's login-shell environment (PATH etc.), shared with the Copilot engine.
    private(set) static var shellEnvironment: [String: String]?

    // Conversation continuity: a restarted process picks up the same chat via --resume.
    private(set) var sessionId: String?
    private var resumedSessionId: String?        // id this process was launched with
    private var sawInit = false                   // the CLI announced itself (resume accepted)
    private var messagesToProcess: [String] = []  // re-sent if the resume is rejected
    private var replyText = ""                    // streamed text of the current answer

    // Read at launch; change them with applySettings(newConversation:).
    var workingDirectory = FileManager.default.homeDirectoryForCurrentUser
    var allowsEdits = true

    /// Points at a specific claude binary (custom installs, tests). Ignored unless it's executable.
    static let claudePathOverrideVariable = "CLAUDE_PET_CLAUDE_PATH"

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onNotice: ((String) -> Void)?                     // markdown; may hold claudepet:// action links
    var onToolUse: ((String, String) -> Void)?            // toolName, summary
    var onToolResult: ((String, Bool) -> Void)?           // summary, isError
    var onTurnComplete: (() -> Void)?

    struct Message {
        enum Role { case user, assistant, error, notice, toolUse, toolResult }
        let role: Role
        let text: String
    }
    var history: [Message] = []

    private static let notInstalledNotice = """
    **Claude Code isn't installed, so I'm offline.** I'll keep roaming around!
    To chat: [install Claude Code](claudepet://install) (opens Terminal), then send your message again.
    Or download it from https://claude.ai/download
    """
    private static let notLoggedInNotice = """
    **You're not logged in to Claude Code, so I'm offline.**
    [Log in](claudepet://login) (opens Terminal, just follow the steps), then send your message again.
    """
    private static let noConnectionNotice = "**Can't reach Claude right now.** Check your internet connection, then send your message again."
    private static let stoppedNotice = "**Claude stopped.** Send a message to start it again."
    private static let stoppedByUserNotice = "**Stopped.** Send a message to keep going."
    private static let freshStartNotice = "Couldn't pick up the earlier chat, so this is a fresh one."

    // MARK: - Finding Claude

    static func resolveClaudePath(completion: @escaping (String?) -> Void) {
        if let override = ProcessInfo.processInfo.environment[claudePathOverrideVariable],
           FileManager.default.isExecutableFile(atPath: override) {
            completion(override)
            return
        }
        if let cached = claudePath, shellEnvironment != nil,
           FileManager.default.isExecutableFile(atPath: cached) {
            completion(cached)
            return
        }
        // GUI apps get a bare PATH, so ask the user's own shell where things are installed.
        captureLoginShellEnvironment { env in
            if let env { shellEnvironment = env }
            let shellCandidates = (shellEnvironment?["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
            claudePath = (shellCandidates + fallbackPaths()).first { FileManager.default.isExecutableFile(atPath: $0) }
            completion(claudePath)
        }
    }

    private static func fallbackPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.claude/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
            "\(home)/Library/pnpm/claude"
        ]
        // nvm keeps one bin dir per Node version; prefer the newest.
        let nvmRoot = "\(home)/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvmRoot)) ?? []
        paths += versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(nvmRoot)/\($0)/bin/claude" }
        return paths
    }

    private static let envStart = "__CLAUDE_PET_ENV_START__"
    private static let envEnd = "__CLAUDE_PET_ENV_END__"

    /// Captures the login-shell environment once; later calls reuse it.
    static func loadShellEnvironment(completion: @escaping () -> Void) {
        if shellEnvironment != nil { completion(); return }
        captureLoginShellEnvironment { env in
            if let env { shellEnvironment = env }
            completion()
        }
    }

    private static func captureLoginShellEnvironment(completion: @escaping ([String: String]?) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: loginShellPath())
        // -l -i loads the same profile/rc files Terminal does (Homebrew, nvm, PATH tweaks).
        proc.arguments = ["-l", "-i", "-c", "echo \(envStart); /usr/bin/env; echo \(envEnd)"]
        // No stdin: rc files that ask questions get EOF instead of hanging forever.
        proc.standardInput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe

        var finished = false
        let finish: ([String: String]?) -> Void = { env in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.isRunning { proc.terminate() }
                completion(env)
            }
        }

        var output = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            output.append(chunk)
            let text = String(decoding: output, as: UTF8.self)
            if chunk.isEmpty || text.contains(envEnd) {
                handle.readabilityHandler = nil
                finish(parseEnvironment(text))
            }
        }

        do {
            try proc.run()
        } catch {
            finish(nil)
            return
        }
        // A broken shell config must not block chat; fall back to known install paths.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish(nil) }
    }

    private static func parseEnvironment(_ output: String) -> [String: String]? {
        guard let start = output.range(of: envStart + "\n"),
              let end = output.range(of: "\n" + envEnd, range: start.upperBound..<output.endIndex) else { return nil }
        var env: [String: String] = [:]
        for line in output[start.upperBound..<end.lowerBound].split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }

    private static func loginShellPath() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    // MARK: - Terminal Helpers

    @discardableResult
    static func openLoginInTerminal() -> Bool {
        runInTerminal(
            name: "login",
            command: shellQuote(claudePath ?? "claude"),
            banner: "Log in to Claude Code when asked (if it doesn't ask, type /login and press Enter). When you're done, close this window and send your message again."
        )
    }

    @discardableResult
    static func openInstallInTerminal() -> Bool {
        runInTerminal(
            name: "install",
            command: "curl -fsSL https://claude.ai/install.sh | bash",
            banner: "Installing Claude Code. When it finishes, close this window and send your message again."
        )
    }

    static func runInTerminal(name: String, command: String, banner: String) -> Bool {
        let script = """
        #!/bin/sh
        clear
        echo \(shellQuote(banner))
        echo
        exec "${SHELL:-/bin/zsh}" -l -i -c \(shellQuote(command))
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-pet-\(name).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Session Lifecycle

    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        status = .connecting
        ClaudeSession.resolveClaudePath { [weak self] path in
            guard let self else { return }
            self.isStarting = false
            guard let path else {
                self.goOffline("Claude Code not installed", notice: Self.notInstalledNotice)
                return
            }
            self.launchProcess(claudePath: path)
        }
    }

    private func launchProcess(claudePath: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        var arguments = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose"
        ]
        // Without this flag Claude can still read and answer, but won't edit files or run commands.
        if allowsEdits { arguments.append("--dangerously-skip-permissions") }
        if let sessionId { arguments += ["--resume", sessionId] }
        proc.arguments = arguments
        resumedSessionId = sessionId
        sawInit = false
        messagesToProcess = []
        lineBuffer = ""
        outputGeneration += 1
        let generation = outputGeneration

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            proc.currentDirectoryURL = workingDirectory
        } else {
            notice("**Can't find the folder \(Self.displayPath(workingDirectory)),** so Claude is working in your home folder. Pick another one from the menu bar icon → Claude.")
            proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        // Use the shell environment captured from the user's login shell, not Xcode's
        // process environment. Xcode strips PATH and other vars that Claude CLI needs.
        var env = ClaudeSession.shellEnvironment ?? ProcessInfo.processInfo.environment
        // Ensure PATH always includes common locations even if shell capture failed
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let essentialPaths = [
            // npm/nvm installs need `node`, which lives next to `claude`.
            URL(fileURLWithPath: claudePath).deletingLastPathComponent().path,
            "\(home)/.local/bin",
            "\(home)/.local/share/claude/versions",
            "/usr/local/bin",
            "/opt/homebrew/bin"
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        let currentDirs = Set(currentPath.split(separator: ":").map(String.init))
        let missingPaths = essentialPaths.filter { !currentDirs.contains($0) }
        if !missingPaths.isEmpty {
            env["PATH"] = (missingPaths + [currentPath]).joined(separator: ":")
        }
        env["TERM"] = "dumb"
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] exited in
            DispatchQueue.main.async {
                guard let self, self.process === exited else { return }
                let unexpected = self.isRunning
                self.isRunning = false
                self.isBusy = false
                // Exits we caused (terminate / login restart) are already explained in the chat.
                if unexpected {
                    Logger.session.error("Claude exited unexpectedly (status \(exited.terminationStatus, privacy: .public))")
                    self.goOffline("stopped", notice: Self.stoppedNotice)
                }
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty read = EOF; detach or the handler fires forever.
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    guard let self, self.outputGeneration == generation else { return }
                    self.processOutput(text)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    guard let self, self.outputGeneration == generation else { return }
                    self.handleStderr(text)
                }
            }
        }

        do {
            try proc.run()
            Logger.session.info("Claude started (pid \(proc.processIdentifier, privacy: .public), edits \(self.allowsEdits ? "on" : "off", privacy: .public), resume \(self.sessionId != nil, privacy: .public))")
            process = proc
            inputPipe = inPipe
            isRunning = true
            status = needsLogin ? .offline("not logged in") : .ready
            let queued = pendingMessages
            pendingMessages.removeAll()
            queued.forEach(write)
        } catch {
            goOffline("couldn't start", notice: """
            **Couldn't start Claude Code, so I'm offline.** (\(error.localizedDescription))
            [Reinstall Claude Code](claudepet://install), then send your message again.
            """)
        }
    }

    func send(message: String) {
        history.append(Message(role: .user, text: message))
        isBusy = true
        replyText = ""
        guard isRunning else {
            // Starts on demand: first message, after a crash, or after logging in.
            pendingMessages.append(message)
            start()
            return
        }
        write(message)
    }

    /// Ends the current answer. The next message continues the same conversation.
    func stop() {
        guard isBusy else { return }
        Logger.session.info("Stopped by user")
        pendingMessages.removeAll()
        if !replyText.isEmpty {
            history.append(Message(role: .assistant, text: replyText))
            replyText = ""
        }
        terminate()
        isBusy = false
        status = .idle
        notice(Self.stoppedByUserNotice)
    }

    /// Forgets the conversation; the next message starts a brand-new one.
    func reset() {
        Logger.session.info("New chat")
        terminate()
        pendingMessages.removeAll()
        history.removeAll()
        sessionId = nil
        replyText = ""
        isBusy = false
        status = .idle
    }

    /// Restarts Claude so new folder / permission settings apply on the next message.
    func applySettings(newConversation: Bool, notice text: String) {
        if isBusy { stop() }
        terminate()
        status = .idle
        // Saved chats belong to the folder they ran in, so a new folder means a new chat.
        if newConversation { sessionId = nil }
        notice(text)
    }

    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func write(_ message: String) {
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": message
            ]
        ]
        guard let pipe = inputPipe, var data = try? JSONSerialization.data(withJSONObject: payload) else {
            isBusy = false
            return
        }
        data.append(0x0A)
        do {
            try pipe.fileHandleForWriting.write(contentsOf: data)
            messagesToProcess.append(message)
        } catch {
            terminate()
            goOffline("stopped", notice: Self.stoppedNotice)
        }
    }

    func terminate() {
        isRunning = false
        // Anything the old process still prints (half an answer, a late result) must not reach the chat.
        outputGeneration += 1
        process?.terminate()
        process = nil
        inputPipe = nil
    }

    private func goOffline(_ reason: String, notice text: String) {
        Logger.session.notice("Offline: \(reason, privacy: .public)")
        status = .offline(reason)
        isBusy = false
        pendingMessages.removeAll()
        notice(text)
    }

    private func notice(_ text: String) {
        guard history.last?.text != text else { return }
        history.append(Message(role: .notice, text: text))
        onNotice?(text)
    }

    private func reportLoginProblem() {
        needsLogin = true
        // New credentials are only picked up by a fresh process.
        terminate()
        goOffline("not logged in", notice: Self.notLoggedInNotice)
    }

    private func handleStderr(_ text: String) {
        if Self.isLoginProblem(text, isError: true) {
            reportLoginProblem()
        } else if resumedSessionId != nil, text.contains("No conversation found") {
            // Handled when the matching result arrives: we start a fresh chat instead.
            return
        } else {
            onError?(text)
        }
    }

    /// The CLI didn't know the saved chat (deleted, or made in another folder): start fresh and re-send.
    private func recoverFromRejectedResume() {
        Logger.session.notice("Saved chat not found by Claude; starting fresh")
        let unanswered = messagesToProcess
        terminate()
        sessionId = nil
        notice(Self.freshStartNotice)
        guard !unanswered.isEmpty else {
            isBusy = false
            status = .idle
            return
        }
        pendingMessages = unanswered + pendingMessages
        isBusy = true
        start()
    }

    private static func isLoginProblem(_ text: String, isError: Bool) -> Bool {
        let lower = text.lowercased()
        if lower.contains("please run /login") { return true }
        guard isError else { return false }
        return ["invalid api key", "not logged in", "oauth token", "authentication_error", "unauthorized"]
            .contains { lower.contains($0) }
    }

    private static func isConnectionProblem(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["connection error", "network", "enotfound", "econnrefused", "econnreset", "etimedout",
                "fetch failed", "getaddrinfo", "unable to connect", "socket hang up"]
            .contains { lower.contains($0) }
    }

    // MARK: - NDJSON Parsing

    private func processOutput(_ text: String) {
        lineBuffer += text
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])
            if !line.isEmpty {
                parseLine(line)
            }
        }
    }

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = json["type"] as? String ?? ""

        switch type {
        case "system":
            if json["subtype"] as? String == "init" {
                sawInit = true
                if let id = json["session_id"] as? String { sessionId = id }
                break
            }
            // The CLI silently retries failed API calls for minutes; bail out early on the hopeless ones.
            guard json["subtype"] as? String == "api_retry" else { break }
            let httpStatus = json["error_status"] as? Int
            if httpStatus == 401 || json["error"] as? String == "authentication_failed" {
                reportLoginProblem()
            } else if httpStatus == nil, (json["attempt"] as? Int ?? 0) >= 3 {
                terminate()
                goOffline("no internet", notice: Self.noConnectionNotice)
            }

        case "assistant":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    let blockType = block["type"] as? String ?? ""
                    if blockType == "text", let text = block["text"] as? String {
                        // The CLI's own "please run /login" line; our friendly notice replaces it.
                        if Self.isLoginProblem(text, isError: false) { continue }
                        replyText += text
                        onText?(text)
                    } else if blockType == "tool_use" {
                        let toolName = block["name"] as? String ?? "Tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        let summary = formatToolSummary(input)
                        history.append(Message(role: .toolUse, text: "\(toolName): \(summary)"))
                        onToolUse?(toolName, summary)
                    }
                }
            }

        case "user":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if block["type"] as? String == "tool_result" {
                        let isError = block["is_error"] as? Bool ?? false
                        var summary = ""
                        if let resultInfo = json["tool_use_result"] as? [String: Any] {
                            if let text = resultInfo["type"] as? String, text == "text" {
                                if let file = resultInfo["file"] as? [String: Any],
                                   let path = file["filePath"] as? String {
                                    let lines = file["totalLines"] as? Int ?? 0
                                    summary = "\(path) (\(lines) lines)"
                                }
                            }
                        } else if let resultStr = json["tool_use_result"] as? String {
                            summary = String(resultStr.prefix(80))
                        }
                        if summary.isEmpty {
                            if let contentStr = block["content"] as? String {
                                summary = String(contentStr.prefix(80))
                            }
                        }
                        history.append(Message(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
                        onToolResult?(summary, isError)
                    }
                }
            }

        case "result":
            // A rejected --resume answers with an error result before ever sending system/init.
            if resumedSessionId != nil && !sawInit {
                recoverFromRejectedResume()
                return
            }
            if !messagesToProcess.isEmpty { messagesToProcess.removeFirst() }
            isBusy = false
            replyText = ""
            let result = json["result"] as? String ?? ""
            let isError = json["is_error"] as? Bool ?? false
            if Self.isLoginProblem(result, isError: isError) {
                reportLoginProblem()
            } else if isError && Self.isConnectionProblem(result) {
                goOffline("no internet", notice: Self.noConnectionNotice)
            } else {
                needsLogin = false
                status = .ready
                if !result.isEmpty {
                    history.append(Message(role: .assistant, text: result))
                }
            }
            onTurnComplete?()

        default:
            break
        }
    }

    private func formatToolSummary(_ input: [String: Any]) -> String {
        for key in ["command", "file_path", "pattern", "description"] {
            if let value = input[key] as? String { return value }
        }
        return input.keys.sorted().prefix(3).joined(separator: ", ")
    }
}
