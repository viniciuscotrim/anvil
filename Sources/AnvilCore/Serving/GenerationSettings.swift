import Foundation

/// Per-request sampling parameters — the same knobs oMLX/mlx_lm.server
/// expose. Values match mlx_lm.server's own CLI defaults except
/// `maxTokens`, raised a bit so reasoning models are less likely to get
/// cut off before an answer.
public struct GenerationSettings: Codable, Sendable, Equatable {
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var minP: Double

    public init(
        maxTokens: Int = 1024,
        temperature: Double = 0.0,
        topP: Double = 1.0,
        topK: Int = 0,
        minP: Double = 0.0
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
    }

    public static let `default` = GenerationSettings()
}
