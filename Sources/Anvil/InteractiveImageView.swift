import SwiftUI
import AppKit

/// A generated image the user can actually do something with — right-
/// click to copy or reveal in Finder, or Save As… through a real save
/// panel — not just a static picture. Used both inline in chat bubbles
/// and in the Images tab's gallery.
struct InteractiveImageView<ExtraMenuItems: View>: View {
    let path: String
    @ViewBuilder var extraMenuItems: () -> ExtraMenuItems
    @State private var isSavePresented = false

    init(path: String, @ViewBuilder extraMenuItems: @escaping () -> ExtraMenuItems = { EmptyView() }) {
        self.path = path
        self.extraMenuItems = extraMenuItems
    }

    var body: some View {
        Group {
            if let nsImage = Self.cachedImage(at: path) {
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
            Button("Save As…") { isSavePresented = true }
            Button("Reveal in Finder") { revealInFinder() }
            extraMenuItems()
        }
        .fileExporter(
            isPresented: $isSavePresented,
            // Only reads the file when the save panel is actually about
            // to appear — `imageData` isn't evaluated at all otherwise,
            // since this is a plain `? :`, not a value computed above it.
            document: ImageFileDocument(data: isSavePresented ? imageData : Data()),
            contentType: .png,
            defaultFilename: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        ) { _ in }
    }

    private var imageData: Data {
        (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
    }

    private static func cachedImage(at path: String) -> NSImage? {
        InteractiveImageCache.image(at: path)
    }

    private func copyToPasteboard() {
        guard let nsImage = Self.cachedImage(at: path) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// Every generated image is its own immutable file (a new version in a
/// lineage is always a brand-new path, never an overwrite — see
/// `GeneratedImage.versionNumber`), so caching by path alone is always
/// safe: nothing this key ever refers to changes underneath it. Without
/// this, `InteractiveImageView.body` re-decoding a multi-MB PNG from
/// disk on every SwiftUI re-render (any state change in a parent
/// gallery/chat view) was real, avoidable work on the main thread. A
/// plain top-level type (not nested in `InteractiveImageView` itself)
/// because Swift doesn't allow a static stored property inside a
/// generic type.
private enum InteractiveImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(at path: String) -> NSImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
