import SwiftUI
import AppKit
import AnvilCore

/// Anvil's own image-generation UI — the Draw Things replacement half
/// of Phase 4. Model picker + prompt at top, a collapsible settings
/// panel (mirrors Chat's), and a gallery of everything generated so
/// far.
struct ImageGenerationView: View {
    @EnvironmentObject private var imageSessions: ImageSessionManager
    @EnvironmentObject private var viewModel: ImageGenerationViewModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()

                if imageSessions.readySessions.isEmpty {
                    emptyState
                } else {
                    gallery
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.top, 4)
                }

                Divider()
                promptBar
            }
            .frame(minWidth: 560, minHeight: 480)

            if viewModel.isSettingsOpen {
                Divider()
                settingsPanel
                    .frame(width: 260)
            }
        }
        .task {
            viewModel.syncSelectedModel()
            await viewModel.loadGallery()
        }
        .onChange(of: imageSessions.sessions) { _, _ in viewModel.syncSelectedModel() }
    }

    private var header: some View {
        HStack {
            if imageSessions.readySessions.isEmpty {
                Text("Images").font(.headline)
            } else {
                Picker("", selection: Binding(
                    get: { viewModel.selectedModelID },
                    set: { viewModel.selectedModelID = $0 }
                )) {
                    ForEach(imageSessions.readySessions) { session in
                        Text(session.model.displayName).tag(Optional(session.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            Spacer()

            Button {
                viewModel.isSettingsOpen.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No image models loaded")
                .font(.headline)
            Text("Load one from the Models tab first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var gallery: some View {
        ScrollView {
            if viewModel.gallery.isEmpty {
                Text("Nothing generated yet.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(viewModel.gallery) { image in
                        galleryTile(image)
                    }
                }
                .padding()
            }
        }
    }

    private func galleryTile(_ image: GeneratedImage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LocalImageView(path: image.localPath)
                .aspectRatio(CGFloat(image.width) / CGFloat(max(image.height, 1)), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contextMenu {
                    Button("Copy Image") { copyToPasteboard(image) }
                    Button("Reveal in Finder") { revealInFinder(image) }
                    Button("Delete", role: .destructive) { Task { await viewModel.delete(image) } }
                }

            Text(image.prompt)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var promptBar: some View {
        HStack {
            TextField("Describe an image…", text: Binding(
                get: { viewModel.prompt },
                set: { viewModel.prompt = $0 }
            ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { Task { await viewModel.generate() } }
                .disabled(imageSessions.readySessions.isEmpty)

            if viewModel.isGenerating {
                ProgressView().controlSize(.small)
            }

            Button("Generate") { Task { await viewModel.generate() } }
                .disabled(
                    imageSessions.readySessions.isEmpty
                    || viewModel.isGenerating
                    || viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
        }
        .padding()
    }

    private var settingsPanel: some View {
        Form {
            Section("Size") {
                LabeledContent("Width") {
                    TextField("", value: Binding(
                        get: { viewModel.settings.width },
                        set: { viewModel.settings.width = $0 }
                    ), format: .number)
                    .frame(width: 80)
                }
                LabeledContent("Height") {
                    TextField("", value: Binding(
                        get: { viewModel.settings.height },
                        set: { viewModel.settings.height = $0 }
                    ), format: .number)
                    .frame(width: 80)
                }
            }
            Section("Generation") {
                LabeledContent("Steps") {
                    TextField("", value: Binding(
                        get: { viewModel.settings.steps },
                        set: { viewModel.settings.steps = $0 }
                    ), format: .number)
                    .frame(width: 80)
                }
                LabeledContent("Guidance") {
                    TextField("", value: Binding(
                        get: { viewModel.settings.guidance },
                        set: { viewModel.settings.guidance = $0 }
                    ), format: .number)
                    .frame(width: 80)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func copyToPasteboard(_ image: GeneratedImage) {
        guard let nsImage = NSImage(contentsOfFile: image.localPath) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }

    private func revealInFinder(_ image: GeneratedImage) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: image.localPath)])
    }
}

/// Loads a local file path as an image — a thin wrapper since SwiftUI's
/// `Image` has no direct "from local path" initializer on macOS.
private struct LocalImageView: View {
    let path: String

    var body: some View {
        if let nsImage = NSImage(contentsOfFile: path) {
            Image(nsImage: nsImage)
                .resizable()
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}
