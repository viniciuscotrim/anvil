import Foundation

/// A function the model can call mid-conversation — OpenAI's tool-call
/// shape, which `mlx_lm.server` implements. Anvil defines exactly one
/// today (`generate_image`), offered automatically once an image model
/// is loaded; this type stays generic so more can be added later
/// without touching `ChatClient`.
public struct ChatTool: Sendable, Equatable {
    public struct Parameter: Sendable, Equatable {
        public let name: String
        public let type: String
        public let description: String

        public init(name: String, type: String = "string", description: String) {
            self.name = name
            self.type = type
            self.description = description
        }
    }

    public let name: String
    public let description: String
    public let parameters: [Parameter]

    public init(name: String, description: String, parameters: [Parameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// The `generate_image(prompt)` tool the brief calls for — offered
    /// whenever an image model is loaded alongside the chat model.
    /// The description is deliberately explicit about *not* calling it
    /// by default — a real bug found in testing: with the vaguer
    /// original wording ("Generate an image from a text prompt..."),
    /// smaller local models called this tool on nearly every message,
    /// image or not, since it was simply the only tool on offer.
    public static let generateImage = ChatTool(
        name: "generate_image",
        description: "Generate an image from a text prompt. ONLY call this when the user explicitly "
            + "asks you to create, draw, generate, paint, or show them an image (or a variation/edit "
            + "of one already shown). For every other message — including ones that merely mention or "
            + "describe something visual — reply normally in plain text instead; do not call this tool "
            + "to illustrate an answer unless asked to.",
        parameters: [
            Parameter(name: "prompt", description: "A detailed description of the image to generate.")
        ]
    )

    /// Prepended to the system prompt whenever this tool is offered —
    /// belt-and-suspenders alongside the description above, since a
    /// tool's own description competes with everything else in the
    /// model's context and some local models weight it less than a
    /// direct system instruction.
    public static let generateImageUsageDiscipline =
        "You have a generate_image tool available. Only call it when the user explicitly asks for an "
        + "image (create/draw/generate/paint/show/make one, or a variation of one already in this "
        + "conversation). Never call it for an ordinary question or statement, even one about visual "
        + "or descriptive topics — just answer in text."

    // MARK: - Code agent tools

    /// Reading and listing never ask for confirmation, whatever the
    /// user's permission level — only `writeFile`/`runTerminalCommand`
    /// are gated (see `CodeAgentPermissionLevel`).
    public static let readFile = ChatTool(
        name: "read_file",
        description: "Reads the contents of a text file as a string.",
        parameters: [
            Parameter(name: "path", description: "Path to the file, relative to the working folder (or absolute if full-disk access is on).")
        ]
    )

    public static let listDirectory = ChatTool(
        name: "list_directory",
        description: "Lists the immediate contents (files and subdirectories, not recursive) of a directory.",
        parameters: [
            Parameter(name: "path", description: "Directory to list, relative to the working folder. Use \".\" for the working folder itself.")
        ]
    )

    /// Depending on the user's permission level, a call to this may not
    /// take effect immediately — see `CodeAgentPermissionLevel`. The
    /// tool result always says plainly whether it actually ran.
    public static let writeFile = ChatTool(
        name: "write_file",
        description: "Creates a file or overwrites it completely with new content. There is no partial/patch mode — always write the file's full intended contents.",
        parameters: [
            Parameter(name: "path", description: "Path to the file, relative to the working folder."),
            Parameter(name: "content", description: "The complete text content the file should contain after this call.")
        ]
    )

    /// Same permission-gating caveat as `writeFile`.
    public static let runTerminalCommand = ChatTool(
        name: "run_terminal_command",
        description: "Runs one shell command in the working folder and returns its combined stdout/stderr output and exit code.",
        parameters: [
            Parameter(name: "command", description: "The exact shell command to run.")
        ]
    )

    /// Prepended to the system prompt whenever any code-agent tool is
    /// offered. `workingDirectoryDescription` names the actual folder
    /// (or says none is set) so the model reasons about real paths
    /// instead of a placeholder.
    public static func codeAgentUsageDiscipline(workingDirectoryDescription: String) -> String {
        "You are acting as a coding agent with real access to \(workingDirectoryDescription). "
            + "Only call read_file/list_directory/write_file/run_terminal_command when actually useful "
            + "for the task — don't explore files or run commands aimlessly. Prefer paths relative to "
            + "the working folder. A write_file or run_terminal_command call may require the user's "
            + "manual confirmation before it actually happens — its tool result always says plainly "
            + "whether it ran or is only proposed; never assume a proposed-but-unconfirmed change has "
            + "taken effect, and wait for the user before building further on it."
    }

    /// JSON-Schema-shaped, typed request payload — a wrong/misspelled
    /// key here would previously only ever surface as a silent runtime
    /// mismatch (a `[String: Any]` dictionary caught nothing at compile
    /// time); `Encodable` structs make that a compile error instead.
    struct WireToolDefinition: Encodable {
        struct WireFunction: Encodable {
            struct WireParameters: Encodable {
                struct WireProperty: Encodable {
                    let type: String
                    let description: String
                }
                let type = "object"
                let properties: [String: WireProperty]
                let required: [String]
            }
            let name: String
            let description: String
            let parameters: WireParameters
        }
        let type = "function"
        let function: WireFunction
    }

    var wireRepresentation: WireToolDefinition {
        var properties: [String: WireToolDefinition.WireFunction.WireParameters.WireProperty] = [:]
        for parameter in parameters {
            properties[parameter.name] = .init(type: parameter.type, description: parameter.description)
        }
        return WireToolDefinition(function: .init(
            name: name,
            description: description,
            parameters: .init(properties: properties, required: parameters.map(\.name))
        ))
    }
}
