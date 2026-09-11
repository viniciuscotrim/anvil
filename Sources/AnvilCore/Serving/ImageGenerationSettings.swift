import Foundation

/// Per-request image generation parameters, editable in the UI same as
/// `GenerationSettings` for text. Defaults match `mflux-generate`'s own
/// (`schnell`-friendly: few steps, no real guidance scale).
public struct ImageGenerationSettings: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var steps: Int
    public var guidance: Double

    public init(width: Int = 1024, height: Int = 1024, steps: Int = 4, guidance: Double = 4.0) {
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
    }

    public static let `default` = ImageGenerationSettings()
}
