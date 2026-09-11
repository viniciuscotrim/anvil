import Foundation

/// Per-request image generation parameters, editable in the UI same as
/// `GenerationSettings` for text. 512×512 is the default resolution
/// (explicitly requested — faster and lighter than 1024², with the user
/// free to raise it); steps/guidance still match `mflux-generate`'s own
/// (`schnell`-friendly: few steps, no real guidance scale).
public struct ImageGenerationSettings: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var steps: Int
    public var guidance: Double

    public init(width: Int = 512, height: Int = 512, steps: Int = 4, guidance: Double = 4.0) {
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
    }

    public static let `default` = ImageGenerationSettings()
}
