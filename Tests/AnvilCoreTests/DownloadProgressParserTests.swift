import Foundation
import Testing
@testable import AnvilCore

@Suite("DownloadProgressParser")
struct DownloadProgressParserTests {
    @Test
    func parsesARealHuggingFaceHubProgressLine() {
        // Captured for real from an actual snapshot_download run.
        let line = "Fetching 10 files:  70%|███████   | 7/10 [00:00<00:00, 28.37it/s]"
        #expect(DownloadProgressParser.fraction(from: line) == 0.7)
    }

    @Test
    func parsesAPerFileByteProgressLine() {
        let line = "model.safetensors: 45%|████▌     | 450M/1.00G [00:10<00:12, 45.2MB/s]"
        #expect(DownloadProgressParser.fraction(from: line) == 0.45)
    }

    @Test
    func returnsNilForALineWithNoPercentage() {
        #expect(DownloadProgressParser.fraction(from: "Downloading org/model…") == nil)
        #expect(DownloadProgressParser.fraction(from: "") == nil)
    }

    @Test
    func clampsAnOutOfRangeValue() {
        #expect(DownloadProgressParser.fraction(from: "100%|██████████| 10/10") == 1.0)
        #expect(DownloadProgressParser.fraction(from: "0%|          | 0/10") == 0.0)
    }
}
