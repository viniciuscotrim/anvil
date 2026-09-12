import SwiftUI
import AnvilCore

/// A real on-device image generation screen — the built-in `sdxl-turbo`
/// preset, or any registered image model whose folder looks like a real
/// diffusers pipeline (see `StableDiffusionModelLoader`), via
/// `NativeImageEngine`. No server, no network round trip once loaded.
/// Draw-Things-style like the Mac app's Images tab: a gallery grid of
/// past lineages, and a detail canvas with a version-history strip once
/// one is selected.
struct NativeImageView: View {
    @EnvironmentObject private var engine: NativeImageEngine
    @Environment(ModelsViewModel.self) private var modelsViewModel
    @State private var prompt = "a photo of an astronaut riding a horse on the moon"
    @State private var isSettingsPresented = false

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                modelBar
                Divider()

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
                    if engine.selectedImage != nil {
                        Button("New") { engine.deselectImage() }
                    }
                    Spacer()
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isSettingsPresented = true } label: { Image(systemName: "slider.horizontal.3") }
                        .disabled(!engine.isLoaded)
                }
            }
            .sheet(isPresented: $isSettingsPresented) { settingsSheet }
            .task { await engine.loadGallery() }
        }
    }

    /// Which model is loaded (or a menu to load one) — the built-in
    /// preset needs no download-first step, any registered image model
    /// loads straight from its own already-downloaded files.
    private var modelBar: some View {
        HStack {
            if let name = engine.loadedModelDisplayName {
                Label(name, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if engine.isLoading {
                if let progress = engine.loadProgress {
                    ProgressView(value: progress).frame(width: 100)
                    Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("No model loaded").font(.subheadline).foregroundStyle(.secondary)
            }

            Spacer()

            if engine.isLoaded {
                Button("Unload") { engine.unload() }
            } else if !engine.isLoading {
                Menu {
                    Button("SDXL Turbo (built-in)") { Task { await engine.load() } }
                    let imageModels = modelsViewModel.registeredModels.filter { $0.kind == .image }
                    if !imageModels.isEmpty {
                        Divider()
                        ForEach(imageModels) { entry in
                            Button(entry.displayName) { Task { await engine.load(entry: entry) } }
                        }
                    }
                } label: {
                    Label("Load", systemImage: "chevron.down.circle")
                }
            }
        }
        .padding(.horizontal)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Size") {
                    LabeledContent("Width") {
                        TextField("", value: $engine.settings.width, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Height") {
                        TextField("", value: $engine.settings.height, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section("Generation") {
                    LabeledContent("Steps") {
                        TextField("", value: $engine.settings.steps, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Guidance") {
                        TextField("", value: $engine.settings.guidance, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Generation Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isSettingsPresented = false }
                }
            }
            .dismissKeyboardOnTap()
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
