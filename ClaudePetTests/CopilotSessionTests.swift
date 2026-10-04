import AppKit
import XCTest

/// A stand-in for `copilot -p … --output-format json` replaying the event shapes of Copilot CLI 1.0.x.
final class FakeCopilot {
    let dir: URL
    private var log: URL { dir.appendingPathComponent("launches.jsonl") }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fakecopilot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let executable = dir.appendingPathComponent("copilot")
        try Self.script(log: log.path).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        setenv(CopilotSession.pathOverrideVariable, executable.path, 1)
    }

    func cleanUp() {
        unsetenv(CopilotSession.pathOverrideVariable)
        try? FileManager.default.removeItem(at: dir)
    }

    struct Launch {
        let args: [String]
        let cwd: String
        let pid: Int32
        var sessionId: String? { args.firstIndex(of: "--session-id").map { args[$0 + 1] } }
    }

    var launches: [Launch] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return Launch(args: json["args"] as? [String] ?? [], cwd: json["cwd"] as? String ?? "", pid: Int32(json["pid"] as? Int ?? 0))
        }
    }

    private static func script(log: String) -> String {
        """
        #!/usr/bin/env python3
        import json, os, sys, time
        args = sys.argv[1:]
        msg = args[args.index("-p") + 1]
        sid = args[args.index("--session-id") + 1] if "--session-id" in args else "none"
        with open(\(String(reflecting: log)), "a") as f:
            f.write(json.dumps({"args": args, "cwd": os.getcwd(), "pid": os.getpid()}) + "\\n")
        def emit(t, data=None, **extra):
            sys.stdout.write(json.dumps(dict(type=t, data=data or {}, **extra)) + "\\n"); sys.stdout.flush()
        emit("session.tools_updated", {"model": "fake"}, ephemeral=True)
        if msg == "logged-out":
            sys.stderr.write("Error: No authentication information found. Please run copilot login.\\n"); sys.exit(1)
        if msg == "crash":
            sys.stderr.write("boom\\n"); sys.exit(3)
        emit("assistant.turn_start", {"turnId": "0"})
        if msg == "tool":
            emit("assistant.message", {"content": "Listing files."})
            emit("tool.execution_start", {"toolName": "bash", "arguments": {"command": "ls", "description": "List"}})
            emit("tool.execution_complete", {"success": True, "result": {"content": "a.txt\\n<shellId: 0 completed with exit code 0>"}})
            emit("tool.execution_start", {"toolName": "create", "arguments": {"path": "/tmp/x.txt"}})
            emit("tool.execution_complete", {"success": False})
            emit("assistant.message", {"content": "a.txt"})
        elif msg.startswith("slow"):
            for i in range(12):
                emit("assistant.message", {"content": "chunk%d" % i}); time.sleep(0.25)
        else:
            emit("assistant.message_delta", {"deltaContent": "echo"}, ephemeral=True)
            emit("assistant.message", {"content": "echo: " + msg})
        emit("assistant.turn_end", {"turnId": "0"})
        sys.stdout.write(json.dumps({"type": "result", "sessionId": sid, "exitCode": 0}) + "\\n"); sys.stdout.flush()
        """
    }
}

final class CopilotSessionTests: XCTestCase {
    private var fake: FakeCopilot!
    private var session: CopilotSession!
    private var probe: SessionProbe!
    private var tools: [(String, String)] = []
    private var results: [(String, Bool)] = []

    override func setUpWithError() throws {
        fake = try FakeCopilot()
        session = CopilotSession()
        probe = SessionProbe(session)
        tools = []
        results = []
        session.onToolUse = { [unowned self] in tools.append(($0, $1)) }
        session.onToolResult = { [unowned self] in results.append(($0, $1)) }
    }

    override func tearDown() {
        session.terminate()
        fake.cleanUp()
    }

    private func send(_ text: String) {
        let before = probe.turns
        session.send(message: text)
        XCTAssertTrue(TestSupport.wait { probe.turns == before + 1 }, "no answer to \(text)")
    }

    func testAnswersAndContinuesOneConversation() {
        send("hello")
        XCTAssertEqual(session.history.last?.text, "echo: hello")
        XCTAssertEqual(probe.texts, ["echo: hello"], "only whole messages, not token fragments")
        send("again")
        let launches = fake.launches
        XCTAssertEqual(launches.count, 2)
        XCTAssertNotNil(launches[0].sessionId)
        XCTAssertEqual(launches[0].sessionId, launches[1].sessionId, "second message continues the same conversation")
        XCTAssertTrue(launches[0].args.contains("--allow-all-tools"))
        XCTAssertFalse(launches[0].args.contains("--deny-tool"))
        XCTAssertEqual(session.status, .ready)
        XCTAssertFalse(session.isBusy)
    }

    func testToolStepsAreShown() {
        send("tool")
        XCTAssertEqual(tools.map(\.0), ["Bash", "Edit"])
        XCTAssertEqual(tools.first?.1, "ls")
        XCTAssertEqual(results.first?.0, "a.txt")
        XCTAssertEqual(results.first?.1, false)
        XCTAssertEqual(results.last?.1, true, "failed/blocked tool is shown as an error")
        XCTAssertEqual(session.history.last?.text, "Listing files.\n\na.txt")
    }

    func testEditsOffBlocksShellAndWrites() {
        session.allowsEdits = false
        send("hello")
        let args = fake.launches.last!.args
        XCTAssertTrue(args.contains("--allow-all-tools"), "required without a terminal")
        XCTAssertEqual(args.filter { $0 == "--deny-tool" }.count, 2)
        XCTAssertTrue(args.contains("shell"))
        XCTAssertTrue(args.contains("write"))
    }

    func testStopKeepsPartialReplyAndNextMessageContinues() {
        session.send(message: "slow please")
        TestSupport.wait { probe.texts.count >= 3 }
        let first = fake.launches.last!
        session.stop()
        let textsAtStop = probe.texts.count
        XCTAssertFalse(session.isBusy)
        XCTAssertTrue(session.history.contains { $0.role == .assistant && $0.text.hasPrefix("chunk0") })
        XCTAssertTrue(session.history.last!.text.contains("Stopped"))
        TestSupport.spin(3.5)
        XCTAssertEqual(probe.texts.count, textsAtStop, "late output reached the chat")
        XCTAssertNotEqual(kill(first.pid, 0), 0, "copilot process still running")
        send("again")
        XCTAssertEqual(fake.launches.last!.sessionId, first.sessionId)
    }

    func testNewChatStartsANewConversation() {
        send("hello")
        let first = fake.launches.last!.sessionId
        session.reset()
        XCTAssertTrue(session.history.isEmpty)
        send("fresh")
        XCTAssertNotEqual(fake.launches.last!.sessionId, first)
    }

    func testMessagesSentWhileBusyAreAnsweredInOrder() {
        session.send(message: "slow 1")
        session.send(message: "second")
        XCTAssertTrue(TestSupport.wait(10) { probe.turns == 2 })
        XCTAssertEqual(fake.launches.count, 2, "one copilot at a time")
        XCTAssertEqual(session.history.last?.text, "echo: second")
        XCTAssertFalse(session.isBusy)
    }

    func testLoggedOutShowsLoginNotice() {
        session.send(message: "logged-out")
        XCTAssertTrue(TestSupport.wait { session.status == .offline("not logged in") })
        XCTAssertTrue(probe.notices.contains { $0.contains("not logged in to GitHub Copilot") })
        XCTAssertFalse(session.isBusy)
    }

    func testCrashShowsErrorAndRecovers() {
        session.send(message: "crash")
        XCTAssertTrue(TestSupport.wait { probe.notices.contains { $0.contains("stopped unexpectedly") } })
        XCTAssertEqual(probe.errors.last, "boom")
        XCTAssertFalse(session.isBusy)
        send("hello")
        XCTAssertEqual(session.history.last?.text, "echo: hello")
    }

    func testMissingFolderFallsBackToHome() {
        session.workingDirectory = fake.dir.appendingPathComponent("gone")
        send("where")
        XCTAssertEqual(fake.launches.last!.cwd, NSHomeDirectory())
        XCTAssertTrue(probe.notices.contains { $0.contains("Can't find the folder") })
    }

    func testThemesNameTheActiveAssistant() {
        let titles = PopoverTheme.allThemes.map { $0.statusTitle(for: .copilot) }
        XCTAssertTrue(titles.allSatisfy { $0.lowercased().contains("copilot") }, "\(titles)")
        XCTAssertFalse(titles.contains { $0.lowercased().contains("claude") }, "\(titles)")
        XCTAssertEqual(PopoverTheme.midnight.statusTitle(for: .copilot), "COPILOT")
        XCTAssertEqual(PopoverTheme.midnight.statusTitle(for: .claude), "CLAUDE")
    }
}
