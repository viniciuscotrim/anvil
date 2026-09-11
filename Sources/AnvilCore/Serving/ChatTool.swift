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

    /// JSON-Schema-shaped dictionary, ready for `JSONSerialization`.
    var wireRepresentation: [String: Any] {
        var properties: [String: Any] = [:]
        for parameter in parameters {
            properties[parameter.name] = ["type": parameter.type, "description": parameter.description]
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": parameters.map(\.name)
                ]
            ]
        ]
    }
}
