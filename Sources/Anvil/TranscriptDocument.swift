import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var markdownTranscript: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }
}

/// Wraps an already-rendered Markdown transcript for `.fileExporter`.
struct TranscriptDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdownTranscript, .plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
