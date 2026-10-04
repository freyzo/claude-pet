import Foundation

/// Which AI answers in the pets' chat.
enum AIProvider: String, CaseIterable {
    case copilot, claude

    static let `default`: AIProvider = .copilot

    /// Short name used in the chat ("Stop Copilot", "Copilot can change files…").
    var assistantName: String { self == .copilot ? "Copilot" : "Claude" }
    var menuTitle: String { self == .copilot ? "GitHub Copilot" : "Claude Code" }
}

/// What a pet's chat needs from an AI command-line tool.
protocol ChatEngine: AnyObject {
    var provider: AIProvider { get }
    var history: [ClaudeSession.Message] { get set }
    var isBusy: Bool { get }
    var status: ClaudeSession.Status { get }
    var workingDirectory: URL { get set }
    var allowsEdits: Bool { get set }

    var onText: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onNotice: ((String) -> Void)? { get set }
    var onToolUse: ((String, String) -> Void)? { get set }
    var onToolResult: ((String, Bool) -> Void)? { get set }
    var onTurnComplete: (() -> Void)? { get set }

    func start()
    func send(message: String)
    func stop()
    func reset()
    func terminate()
    func applySettings(newConversation: Bool, notice text: String)
    /// Handles a claudepet:// link from a notice; false if the action isn't this engine's.
    func perform(action: String) -> Bool
}

extension ClaudeSession: ChatEngine {
    var provider: AIProvider { .claude }

    func perform(action: String) -> Bool {
        switch action {
        case "login": return Self.openLoginInTerminal()
        case "install": return Self.openInstallInTerminal()
        default: return false
        }
    }
}
