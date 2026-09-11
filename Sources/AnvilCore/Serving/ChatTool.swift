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
    public static let generateImage = ChatTool(
        name: "generate_image",
        description: "Generate an image from a text prompt using the loaded image model.",
        parameters: [
            Parameter(name: "prompt", description: "A detailed description of the image to generate.")
        ]
    )

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
