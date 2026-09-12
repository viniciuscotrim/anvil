import SwiftUI
import AnvilCore

/// "Prompt to Model" — describe an image idea in plain language, let
/// whichever text model is loaded in Chat turn it into a tailored
/// prompt, then generate it through the on-device image engine. See
/// `PromptToModelViewModel`'s header for why this is one row instead of
/// the Mac app's per-registered-image-model fan-out.
struct PromptToModelView: View {
    @EnvironmentObject private var chatEngine: NativeChatEngine
    @EnvironmentObject private var imageEngine: NativeImageEngine
    @State private var viewModel = PromptToModelViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Your idea") {
                    TextField("Describe the image…", text: $viewModel.intention, axis: .vertical)
                        .lineLimit(1...4)

                    if !chatEngine.isLoaded {
                        Text("Load a text model in Chat first — it writes the tailored prompt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await viewModel.interpret(using: chatEngine) }
                    } label: {
                        if viewModel.isInterpreting {
                            ProgressView()
                        } else {
                            Text("Interpret")
                        }
                    }
                    .disabled(
                        !chatEngine.isLoaded || viewModel.isInterpreting
                            || viewModel.intention.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage).foregroundStyle(.red).font(.caption)
                    }
                }

                if !viewModel.interpretedPrompt.isEmpty {
                    Section("Tailored prompt (\(imageEngine.loadedModelDisplayName ?? "SDXL Turbo"))") {
                        TextEditor(text: $viewModel.interpretedPrompt)
                            .frame(minHeight: 100)

                        if let image = imageEngine.lastImage {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        if imageEngine.isLoading || imageEngine.isGenerating {
                            ProgressView(
                                value: imageEngine.isLoading
                                    ? (imageEngine.loadProgress ?? 0) : (imageEngine.generationProgress ?? 0))
                        }
                        if let imageError = imageEngine.errorMessage {
                            Text(imageError).foregroundStyle(.red).font(.caption)
                        }

                        Button("Generate") {
                            Task {
                                await imageEngine.load()
                                await imageEngine.generate(prompt: viewModel.interpretedPrompt)
                            }
                        }
                        .disabled(
                            imageEngine.isLoading || imageEngine.isGenerating
                                || viewModel.interpretedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Prompt to Model")
            .dismissKeyboardOnTap()
        }
    }
}
