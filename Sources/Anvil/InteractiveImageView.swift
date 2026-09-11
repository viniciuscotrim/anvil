import SwiftUI
import AppKit

/// A generated image the user can actually do something with — right-
/// click to copy or reveal in Finder, or Save As… through a real save
/// panel — not just a static picture. Used both inline in chat bubbles
/// and in the Images tab's gallery.
struct InteractiveImageView<ExtraMenuItems: View>: View {
    let path: String
    @ViewBuilder var extraMenuItems: () -> ExtraMenuItems
    @StateObject private var state = InteractiveImageState()

    init(path: String, @ViewBuilder extraMenuItems: @escaping () -> ExtraMenuItems = { EmptyView() }) {
        self.path = path
        self.extraMenuItems = extraMenuItems
    }

    var body: some View {
        Group {
            if let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .contextMenu {
            Button("Copy Image") { copyToPasteboard() }
            Button("Save As…") { state.isSavePresented = true }
            Button("Reveal in Finder") { revealInFinder() }
            extraMenuItems()
        }
        .fileExporter(
            isPresented: Binding(
                get: { state.isSavePresented },
                set: { state.isSavePresented = $0 }
            ),
            document: ImageFileDocument(data: imageData),
            contentType: .png,
            defaultFilename: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        ) { _ in }
    }

    private var imageData: Data {
        (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
    }

    private func copyToPasteboard() {
        guard let nsImage = NSImage(contentsOfFile: path) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// Plain `ObservableObject` (not `@State`) — see the toolchain note in
/// README about `@State`.
private final class InteractiveImageState: ObservableObject {
    @Published var isSavePresented = false
}
