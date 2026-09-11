import SwiftUI
import UniformTypeIdentifiers

/// Wraps raw PNG data for `.fileExporter` — used to let the user Save
/// As… an image straight out of a chat bubble or the gallery, not just
/// copy it to the pasteboard.
struct ImageFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
