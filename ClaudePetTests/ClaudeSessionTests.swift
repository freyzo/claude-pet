import XCTest

final class ClaudeSessionTests: XCTestCase {
    private var fake: FakeClaude!
    private var session: ClaudeSession!
    private var probe: SessionProbe!

    override func setUpWithError() throws {
        fake = try FakeClaude()
        session = ClaudeSession()
        probe = SessionProbe(session)
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

    private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    func testFirstMessageRemembersSessionAndAllowsEditsByDefault() {
        send("hello")
        let launch = fake.launches.last!
        XCTAssertTrue(launch.skipsPermissions)
        XCTAssertFalse(launch.resumes)
        XCTAssertNotNil(session.sessionId)
        XCTAssertEqual(session.history.last?.text, "echo: hello")
    }

    func testStopKeepsPartialReplyKillsProcessAndNextMessageResumes() {
        send("hello")
        let sid = session.sessionId
        session.send(message: "slow please")
        TestSupport.wait { probe.texts.filter { $0.hasPrefix("chunk") }.count >= 3 }
        let pid = fake.launches.last!.pid
        let turns = probe.turns
        session.stop()
        let textsAtStop = probe.texts.count

        XCTAssertFalse(session.isBusy)
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.history.contains { $0.role == .assistant && $0.text.hasPrefix("chunk0 chunk1 chunk2") })
        XCTAssertTrue(session.history.last!.text.contains("Stopped"))
        TestSupport.spin(3.5)
        XCTAssertEqual(probe.texts.count, textsAtStop, "late output from the stopped process reached the chat")
        XCTAssertEqual(probe.turns, turns)
        XCTAssertFalse(alive(pid))

        send("again")
        let relaunch = fake.launches.last!
        XCTAssertTrue(relaunch.resumes)
        XCTAssertEqual(relaunch.args.last, sid)
        XCTAssertEqual(session.history.last?.text, "echo: again")
    }

    func testRejectedResumeStartsFreshAndAnswersOnce() {
        send("hello")
        let oldId = session.sessionId
        fake.forgetSessions()
        session.terminate()
        let before = fake.launches.count
        let errors = probe.errors.count
        send("after-forget")

        let launches = Array(fake.launches.dropFirst(before))
        XCTAssertEqual(launches.count, 2)
        XCTAssertTrue(launches[0].resumes)
        XCTAssertFalse(launches[1].resumes)
        XCTAssertEqual(session.history.last?.text, "echo: after-forget")
        XCTAssertEqual(probe.errors.count, errors, "'No conversation found' leaked into the chat")
        XCTAssertTrue(probe.notices.contains { $0.contains("fresh one") })
        XCTAssertNotEqual(session.sessionId, oldId)
    }

    func testNewChatClearsEverythingAndKillsInFlightAnswer() {
        session.send(message: "slow 2")
        TestSupport.wait { probe.texts.last?.hasPrefix("chunk1") == true }
        let pid = fake.launches.last!.pid
        let texts = probe.texts.count
        session.reset()

        XCTAssertTrue(session.history.isEmpty)
        XCTAssertNil(session.sessionId)
        XCTAssertFalse(session.isBusy)
        TestSupport.spin(3.5)
        XCTAssertEqual(probe.texts.count, texts)
        XCTAssertTrue(session.history.isEmpty)
        XCTAssertFalse(alive(pid))

        send("fresh")
        XCTAssertFalse(fake.launches.last!.resumes)
    }

    func testEditsOffDropsSkipFlagOnEveryLaunchPath() throws {
        let work = fake.dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        session.allowsEdits = false
        session.workingDirectory = work
        session.applySettings(newConversation: true, notice: "now in work")
        send("in work")
        let first = fake.launches.last!
        XCTAssertFalse(first.skipsPermissions)
        XCTAssertFalse(first.resumes, "a new folder must start a new conversation")
        XCTAssertEqual(URL(fileURLWithPath: first.cwd).resolvingSymlinksInPath().path, work.resolvingSymlinksInPath().path)

        let sid = session.sessionId
        session.applySettings(newConversation: false, notice: "permission change")
        send("perm resume")
        let resumed = fake.launches.last!
        XCTAssertTrue(resumed.resumes)
        XCTAssertEqual(resumed.args.last, sid)
        XCTAssertFalse(resumed.skipsPermissions)

        fake.forgetSessions()
        session.terminate()
        let before = fake.launches.count
        send("forgotten again")
        let recovery = Array(fake.launches.dropFirst(before))
        XCTAssertEqual(recovery.count, 2)
        XCTAssertTrue(recovery.allSatisfy { !$0.skipsPermissions })
    }

    func testMissingFolderFallsBackToHomeWithNotice() {
        session.workingDirectory = fake.dir.appendingPathComponent("gone")
        send("where am i")
        XCTAssertEqual(fake.launches.last!.cwd, NSHomeDirectory())
        XCTAssertTrue(probe.notices.contains { $0.contains("Can't find the folder") })
        XCTAssertFalse(probe.notices.contains { $0.contains("Couldn't start") })
    }

    func testLoggedOutShowsOnlyTheFriendlyNoticeNotTheRawCLILine() {
        send("logged-out")
        XCTAssertFalse(probe.texts.contains { $0.contains("Please run /login") }, "raw CLI line reached the chat")
        XCTAssertTrue(probe.notices.contains { $0.contains("not logged in") })
        XCTAssertEqual(session.status, .offline("not logged in"))
    }

    func testNonExecutableOverrideIsIgnored() throws {
        let notExec = fake.dir.appendingPathComponent("not-executable")
        try "x".write(to: notExec, atomically: true, encoding: .utf8)
        setenv(ClaudeSession.claudePathOverrideVariable, notExec.path, 1)
        var resolved: String?
        var finished = false
        ClaudeSession.resolveClaudePath { path in
            resolved = path
            finished = true
        }
        TestSupport.wait(15) { finished }
        XCTAssertTrue(finished)
        XCTAssertNotEqual(resolved, notExec.path)
    }
}
