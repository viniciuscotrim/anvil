import Foundation

/// Renders a conversation as Markdown for export/copy — plain enough to
/// paste anywhere, formatted enough to keep speaker turns and structure
/// readable.
public enum TranscriptFormatter {
    public static func markdown(
        modelName: String,
        messages: [ChatMessage],
        generatedAt: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append("# Conversation with \(modelName)")
        lines.append("")
        lines.append("_Exported \(isoFormatter.string(from: generatedAt))_")

        for message in messages {
            lines.append("")
            lines.append("**\(heading(for: message.role)):**")
            lines.append("")
            lines.append(message.content)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func heading(for role: ChatMessage.Role) -> String {
        switch role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .system: return "System"
        case .tool: return "Tool"
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
