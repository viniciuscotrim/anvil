import SwiftUI
import AppKit
import AnvilCore

/// Anvil's own image-generation UI — the Draw Things replacement half
/// of Phase 4. Model picker + prompt at top, a gallery of lineages (one
/// tile per generated image family), and — once one's selected — a
/// detail canvas with a vertical version-history carousel: generating
/// again from there adds a new version to that same lineage (even
/// across a model change) instead of overwriting anything.
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
                } else if let selected = viewModel.selectedImage {
                    detailCanvas(selected)
                } else if viewModel.gallery.isEmpty {
                    Text("Nothing generated yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            if viewModel.selectedImage != nil {
                Divider()
                versionHistoryCarousel
                    .frame(width: 160)
            }

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
                .help("Used for the next Generate — pick a different one to add a new version under a different model.")
            }

            Spacer()

            if viewModel.selectedImage != nil {
                Button {
                    viewModel.deselectImage()
                } label: {
                    Label("Gallery", systemImage: "square.grid.2x2")
                }
                .help("Back to the gallery — the next Generate also starts a new image instead of a new version.")
            }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Gallery (one tile per lineage)

    private var gallery: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(viewModel.gallery) { image in
                    galleryTile(image)
                }
            }
            .padding()
        }
    }

    private func galleryTile(_ image: GeneratedImage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            InteractiveImageView(path: image.localPath) {
                Button("Delete", role: .destructive) { Task { await viewModel.delete(image) } }
            }
            .aspectRatio(CGFloat(image.width) / CGFloat(max(image.height, 1)), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { Task { await viewModel.selectImage(image) } }

            HStack {
                Text(image.prompt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if image.versionNumber > 1 {
                    Text("v\(image.versionNumber)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Detail canvas (one image, shown large)

    private func detailCanvas(_ image: GeneratedImage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                InteractiveImageView(path: image.localPath) {
                    Button("Delete", role: .destructive) { Task { await viewModel.delete(image) } }
                }
                .aspectRatio(CGFloat(image.width) / CGFloat(max(image.height, 1)), contentMode: .fit)
                .frame(maxWidth: 520)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt").font(.caption).foregroundStyle(.secondary)
                    Text(image.prompt).textSelection(.enabled)
                    Text("Version \(image.versionNumber) · \(image.modelDisplayName) · seed \(image.seed) · \(image.width)×\(image.height)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 520)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Version history (vertical carousel)

    private var versionHistoryCarousel: some View {
        VStack(spacing: 0) {
            Text("History")
                .font(.headline)
                .padding(10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    // Newest at top, matching Draw Things.
                    ForEach(viewModel.selectedLineageVersions.reversed()) { version in
                        versionThumbnail(version)
                    }
                }
                .padding(10)
            }
        }
    }

    private func versionThumbnail(_ version: GeneratedImage) -> some View {
        let isSelected = viewModel.selectedImage?.id == version.id
        return VStack(alignment: .leading, spacing: 2) {
            InteractiveImageView(path: version.localPath) {
                Button("Delete", role: .destructive) { Task { await viewModel.delete(version) } }
            }
            .aspectRatio(CGFloat(version.width) / CGFloat(max(version.height, 1)), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
            .onTapGesture { Task { await viewModel.selectImage(version) } }

            Text("v\(version.versionNumber) · \(version.modelDisplayName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Input

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
                CircularProgressView(fraction: viewModel.generationProgress)
                    .frame(width: 18, height: 18)
            }

            Button(viewModel.selectedImage == nil ? "Generate" : "New Version") {
                Task { await viewModel.generate() }
            }
            .help(
                viewModel.selectedImage == nil
                ? "Starts a new image."
                : "Adds a new version to this image's history — doesn't overwrite it, even if you changed the model."
            )
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
}
