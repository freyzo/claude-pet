import AppKit
import XCTest

/// Shared helpers: run-loop waiting, a fake `claude` CLI, and paths into the repo.
enum TestSupport {
    static let petColor = NSColor(red: 1.0, green: 0.42, blue: 0.0, alpha: 1.0)

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    static func sprite(_ name: String) -> CGImage {
        let url = repoRoot.appendingPathComponent("ClaudePet/Assets.xcassets/\(name).imageset/\(name)@2x.png")
        let data = try! Data(contentsOf: url)
        return NSBitmapImageRep(data: data)!.cgImage!
    }

    static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    static func wait(_ timeout: Double = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            spin(0.02)
        }
        return condition()
    }

    /// A pet with a window and sprite layer like after setup(), minus the asset catalog.
    static func makePet() -> WalkerCharacter {
        _ = NSApplication.shared
        let pet = WalkerCharacter(spriteIdleName: "x", spriteWalk1Name: "y", spriteWalk2Name: "z")
        pet.characterColor = petColor
        pet.displayHeight = 160
        pet.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
        pet.spriteLayer = CALayer()
        return pet
    }
}

/// A stand-in for the real CLI that replays its stream-json event shapes (captured from Claude Code 2.1.x).
final class FakeClaude {
    let dir: URL
    var executable: URL { dir.appendingPathComponent("claude") }
    private var log: URL { dir.appendingPathComponent("launches.jsonl") }
    private var sessions: URL { dir.appendingPathComponent("sessions.txt") }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fakeclaude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.script(log: log.path, sessions: sessions.path).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        setenv(ClaudeSession.claudePathOverrideVariable, executable.path, 1)
    }

    func cleanUp() {
        unsetenv(ClaudeSession.claudePathOverrideVariable)
        try? FileManager.default.removeItem(at: dir)
    }

    struct Launch {
        let args: [String]
        let cwd: String
        let pid: Int32
        var resumes: Bool { args.contains("--resume") }
        var skipsPermissions: Bool { args.contains("--dangerously-skip-permissions") }
    }

    var launches: [Launch] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return Launch(args: json["args"] as? [String] ?? [], cwd: json["cwd"] as? String ?? "", pid: Int32(json["pid"] as? Int ?? 0))
        }
    }

    /// Makes the CLI forget every saved chat, so the next --resume is rejected.
    func forgetSessions() {
        try? "".write(to: sessions, atomically: true, encoding: .utf8)
    }

    private static func script(log: String, sessions: String) -> String {
        """
        #!/usr/bin/env python3
        import json, os, sys, time, uuid
        LOG, SESSIONS = \(String(reflecting: log)), \(String(reflecting: sessions))
        args = sys.argv[1:]
        known = set(open(SESSIONS).read().split()) if os.path.exists(SESSIONS) else set()
        resume = args[args.index("--resume") + 1] if "--resume" in args else None
        with open(LOG, "a") as f:
            f.write(json.dumps({"args": args, "cwd": os.getcwd(), "pid": os.getpid()}) + "\\n")
        def emit(o):
            sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
        if resume and resume not in known:
            emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "num_turns": 0, "session_id": resume})
            sys.stderr.write("No conversation found with session ID: " + resume + "\\n"); sys.stderr.flush()
            sys.exit(1)
        sid = resume or str(uuid.uuid4())
        if not resume:
            with open(SESSIONS, "a") as f: f.write(sid + "\\n")
        for line in sys.stdin:
            msg = json.loads(line)["message"]["content"]
            emit({"type": "system", "subtype": "init", "session_id": sid})
            if msg == "logged-out":
                emit({"type": "assistant", "message": {"content": [{"type": "text", "text": "Not logged in \\u00b7 Please run /login"}]}})
                emit({"type": "result", "subtype": "success", "is_error": True, "result": "Not logged in \\u00b7 Please run /login", "session_id": sid})
                continue
            reply = "echo: " + msg
            if "slow" in msg:
                for i in range(12):
                    emit({"type": "assistant", "message": {"content": [{"type": "text", "text": "chunk%d " % i}]}})
                    time.sleep(0.25)
                reply = "slow done"
            else:
                emit({"type": "assistant", "message": {"content": [{"type": "text", "text": reply}]}})
            emit({"type": "result", "subtype": "success", "is_error": False, "result": reply, "session_id": sid, "num_turns": 1})
        """
    }
}

/// Counts callbacks from a ClaudeSession.
final class SessionProbe {
    var texts: [String] = [], errors: [String] = [], notices: [String] = [], turns = 0

    init(_ session: ClaudeSession) {
        session.onText = { [unowned self] in texts.append($0) }
        session.onError = { [unowned self] in errors.append($0) }
        session.onNotice = { [unowned self] in notices.append($0) }
        session.onTurnComplete = { [unowned self] in turns += 1 }
    }
}
