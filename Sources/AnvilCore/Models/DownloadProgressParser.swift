import Foundation

/// Extracts a 0...1 completion fraction from one line of
/// `huggingface_hub`'s own tqdm-style download progress output (e.g.
/// `"Fetching 10 files:  70%|███████   | 7/10 [00:00<00:00, 28.37it/s]"`).
/// tqdm's default bar format always puts `NN%|` right after the
/// description, so that one pattern is enough without needing to know
/// the exact wording of whichever bar produced it (a file count, a
/// byte count, …) — `nil` when the line has no such pattern, which is
/// most lines (plain log output, warnings, the final printed path).
public enum DownloadProgressParser {
    public static func fraction(from line: String) -> Double? {
        guard let range = line.range(of: #"(\d{1,3})%\|"#, options: .regularExpression) else { return nil }
        let digits = line[range].prefix(while: { $0.isNumber })
        guard let value = Double(digits) else { return nil }
        return min(max(value / 100, 0), 1)
    }
}
