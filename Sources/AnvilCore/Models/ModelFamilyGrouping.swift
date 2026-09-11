import Foundation

/// Groups registered models by their underlying "family" — every
/// "Qwen3.5" size/quantization variant together, "FLUX.2-klein" its
/// own, etc. — for display in the Models tab. Purely a display
/// grouping; nothing about it touches the registry.
public enum ModelFamilyGrouping {
    public struct Family: Identifiable, Sendable, Equatable {
        public let name: String
        public let models: [ModelEntry]
        public var id: String { name }
    }

    public static func group(_ entries: [ModelEntry]) -> [Family] {
        var groups: [String: [ModelEntry]] = [:]
        for entry in entries {
            groups[familyName(for: entry.displayName), default: []].append(entry)
        }
        return groups
            .map { name, models in
                Family(name: name, models: models.sorted { $0.displayName < $1.displayName })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Everything in a model's display name up to (not including) the
    /// first token that looks like a size ("9B", "4b", "135M") or a
    /// quantization/dtype tag ("4bit", "bf16", "mxfp8", "q4", …) — the
    /// part of an HF-style repo name that actually names the model,
    /// with the variant-specific suffix stripped off. Falls back to the
    /// whole name when nothing matches, so an unusually-named model
    /// just becomes its own singleton group rather than an error.
    public static func familyName(for displayName: String) -> String {
        let tokens = displayName.split(separator: "-").map(String.init)
        var familyTokens: [String] = []
        for token in tokens {
            if looksLikeVariantToken(token) { break }
            familyTokens.append(token)
        }
        let family = familyTokens.joined(separator: "-")
        return family.isEmpty ? displayName : family
    }

    private static let knownQuantTokens: Set<String> = [
        "4bit", "8bit", "6bit", "3bit", "2bit", "1bit",
        "bf16", "fp16", "fp32", "f16", "f32",
        "mxfp4", "mxfp6", "mxfp8", "nvfp4", "nvfp8",
        "int4", "int8", "mlx"
    ]

    private static func looksLikeVariantToken(_ token: String) -> Bool {
        let lower = token.lowercased()
        if knownQuantTokens.contains(lower) { return true }
        // Sizes: "9b", "4m", "1.7b" — a leading number ending in a
        // single letter unit.
        if lower.range(of: #"^\d+(\.\d+)?[a-z]$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^q\d+$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^\d+bit$"#, options: .regularExpression) != nil { return true }
        return false
    }
}
