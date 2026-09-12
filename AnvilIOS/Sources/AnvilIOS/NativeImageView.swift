import SwiftUI

/// A real on-device image generation screen — SDXL Turbo via
/// `NativeImageEngine`, no server, no network round trip once loaded.
struct NativeImageView: View {
    @StateObject private var engine = NativeImageEngine()
    @State private var prompt = "a photo of an astronaut riding a horse on the moon"

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let image = engine.lastImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)
                } else {
                    Spacer()
                    Image(systemName: "photo")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Spacer()
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
                    Button("Generate") { Task { await engine.generate(prompt: prompt) } }
                        .disabled(!engine.isLoaded || engine.isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Images (on-device)")
        }
    }
}
