import Foundation

/// Per-request sampling parameters — the same knobs oMLX/mlx_lm.server
/// expose.
public struct GenerationSettings: Codable, Sendable, Equatable {
    /// `nil` means "no explicit cap" — the default, and what stays in
    /// effect unless the user types a number in Chat's sidebar.
    /// `mlx_lm.server` has no real "unlimited" of its own (omitting
    /// `max_tokens` falls back to its own `--max-tokens` CLI default,
    /// 512 — worse than what this used to send) — a reasoning model
    /// alone can burn through a four-figure budget on thinking before it
    /// ever reaches an answer, which is exactly the cut-off-before-an-
    /// answer bug this fixes.
    ///
    /// `wireMaxTokens` is what actually goes on the wire when this is
    /// nil, and it is deliberately *not* some enormous number — a real
    /// test on this machine sent a literal 1,000,000 and hit a genuine
    /// hang: a local Qwen3.5 checkpoint never emitted its stop token for
    /// a trivial three-word prompt and just kept generating, still
    /// running (CPU pegged, memory climbing) past three minutes with no
    /// way to cancel it from the UI. `effectivelyUnlimited` is instead
    /// large enough that no realistic reply — reasoning included — ever
    /// gets cut short, while bounding how long a model that fails to
    /// stop can run for to something recoverable rather than indefinite.
    public var maxTokens: Int?
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var minP: Double

    public init(
        maxTokens: Int? = nil,
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

    public static let effectivelyUnlimited = 8192

    public var wireMaxTokens: Int {
        maxTokens ?? Self.effectivelyUnlimited
    }
}
