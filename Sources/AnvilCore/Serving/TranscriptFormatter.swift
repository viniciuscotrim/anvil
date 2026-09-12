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

    /// A fuller export for a Code conversation — includes tool calls and
    /// their results as their own labeled, timestamped sections, unlike
    /// `markdown(modelName:messages:)`'s plain narrative shape. A Code
    /// conversation's whole value as a reference is *what it actually
    /// read/wrote/ran*, not just what it said — dropping that (the way
    /// feeding it through the plain formatter would, since `.tool`
    /// messages and empty-content-with-toolCalls assistant messages
    /// carry no narrative text of their own) would export something
    /// with the exact gaps the export exists to avoid. Every section
    /// carries the message's own timestamp and, for a tool call, its
    /// exact (pretty-printed) arguments — traceable enough to hand to a
    /// separate conversation as a reference without losing which action
    /// produced which result.
    public static func codeAgentMarkdown(
        threadTitle: String,
        workingDirectoryPath: String?,
        messages: [ChatMessage],
        generatedAt: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append("# Code Session: \(threadTitle)")
        lines.append("")
        lines.append("_Exported \(isoFormatter.string(from: generatedAt))_")
        lines.append("_Working folder: \(workingDirectoryPath ?? "(none set)")_")

        for message in messages {
            lines.append("")
            lines.append("---")
            let timestamp = isoFormatter.string(from: message.createdAt)

            switch message.role {
            case .user:
                lines.append("")
                lines.append("## [\(timestamp)] You")
                lines.append("")
                lines.append(message.content)

            case .assistant:
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    for call in toolCalls {
                        lines.append("")
                        lines.append("## [\(timestamp)] Assistant → \(call.name)")
                        lines.append("")
                        lines.append("```json")
                        lines.append(prettyPrintedArguments(call.argumentsJSON))
                        lines.append("```")
                    }
                }
                if !message.content.isEmpty {
                    lines.append("")
                    let modelSuffix = message.modelDisplayName.map { " (\($0))" } ?? ""
                    lines.append("## [\(timestamp)] Assistant\(modelSuffix)")
                    lines.append("")
                    lines.append(message.content)
                }

            case .tool:
                lines.append("")
                lines.append("## [\(timestamp)] Tool Result")
                lines.append("")
                lines.append("```")
                lines.append(message.content)
                lines.append("```")

            case .system:
                continue
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Re-serializes a tool call's raw wire-format JSON arguments with
    /// indentation and sorted keys, for a readable export — falls back
    /// to the raw string unchanged if it somehow isn't valid JSON rather
    /// than dropping it.
    private static func prettyPrintedArguments(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let string = String(data: pretty, encoding: .utf8)
        else {
            return json
        }
        return string
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
