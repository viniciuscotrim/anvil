import Foundation

/// One capability the Code agent can be given — each independently
/// toggleable, off by default, so the user decides what it's allowed to
/// touch rather than getting everything at once.
public enum CodeAgentFeature: String, Codable, CaseIterable, Sendable, Identifiable {
    case fileAccess
    case terminal

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fileAccess: return "File Access"
        case .terminal: return "Terminal"
        }
    }

    public var summary: String {
        switch self {
        case .fileAccess: return "Read, list, and write files in the working folder."
        case .terminal: return "Run shell commands in the working folder."
        }
    }
}

/// How much a proposed write or terminal command needs the user's
/// go-ahead before it actually runs. Reading/listing files never asks,
/// regardless of this setting — only `write_file`/`run_terminal_command`
/// are gated.
public enum CodeAgentPermissionLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Never executes on its own — the proposed file content or command
    /// is shown with a Copy button so the user applies/runs it
    /// themselves, then tells the agent when it's done.
    case manual
    /// A command/write not seen before in this session asks for
    /// Approve/Deny inline; once approved, an identical one later in the
    /// same session runs automatically without asking again.
    case semiAuto
    /// Runs immediately, no confirmation — only what's covered by the
    /// enabled features and the working-folder scope.
    case auto

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .manual: return "Manual"
        case .semiAuto: return "Semi-Auto"
        case .auto: return "Auto"
        }
    }

    public var explanation: String {
        switch self {
        case .manual:
            return "Prepares file changes and commands for you to copy and run yourself — never executes on its own."
        case .semiAuto:
            return "Asks once per new command or file change; repeats of something you already approved run automatically."
        case .auto:
            return "Runs file changes and commands immediately, without asking."
        }
    }
}
