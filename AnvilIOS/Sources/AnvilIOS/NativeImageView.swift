import SwiftUI
import AnvilCore

/// A real on-device image generation screen — SDXL Turbo via
/// `NativeImageEngine`, no server, no network round trip once loaded.
/// Draw-Things-style like the Mac app's Images tab: a gallery grid of
/// past lineages, and a detail canvas with a version-history strip once
/// one is selected.
struct NativeImageView: View {
    @EnvironmentObject private var engine: NativeImageEngine
    @State private var prompt = "a photo of an astronaut riding a horse on the moon"

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                canvas

                if !engine.selectedLineageVersions.isEmpty {
                    versionStrip
                }

                if let errorMessage = engine.errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.caption).padding(.horizontal)
                }

                if engine.isLoading || engine.isGenerating {
                    ProgressView(
                        value: engine.isLoading ? (engine.loadProgress ?? 0) : (engine.generationProgress ?? 0)
                    )
                    .padding(.horizontal)
                }

                TextField("Describe an image…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .padding(.horizontal)

                HStack {
                    if engine.isLoaded {
                        Button("Unload") { engine.unload() }
                    } else {
                        Button("Load SDXL Turbo") { Task { await engine.load() } }
                            .disabled(engine.isLoading)
                    }
                    Spacer()
                    if engine.selectedImage != nil {
                        Button("New") { engine.deselectImage() }
                    }
                    Button("Generate") { Task { await engine.generate(prompt: prompt) } }
                        .disabled(!engine.isLoaded || engine.isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal)

                if engine.selectedImage == nil && !engine.gallery.isEmpty {
                    Divider()
                    gallery
                }
            }
            .padding(.bottom, 8)
            .dismissKeyboardOnTap()
            .navigationTitle("Images (on-device)")
            .task { await engine.loadGallery() }
        }
    }

    private var canvas: some View {
        Group {
            if let image = engine.lastImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "photo")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// The selected lineage's versions, oldest to newest — tap one to
    /// swap the canvas to it, exactly like the Mac app's history rail.
    private var versionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(engine.selectedLineageVersions) { version in
                    thumbnail(for: version, isSelected: version.id == engine.selectedImage?.id)
                        .onTapGesture { Task { await engine.selectImage(version) } }
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 84)
    }

    private var gallery: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(engine.gallery) { image in
                    thumbnail(for: image, isSelected: false)
                        .onTapGesture { Task { await engine.selectImage(image) } }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                Task { await engine.delete(image) }
                            }
                        }
                }
            }
            .padding(.horizontal)
        }
        .frame(maxHeight: 220)
    }

    private func thumbnail(for image: GeneratedImage, isSelected: Bool) -> some View {
        Group {
            if let uiImage = UIImage(contentsOfFile: image.localPath) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
}
