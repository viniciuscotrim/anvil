import SwiftUI
import AnvilCore

/// "Prompt to Model": describe an image idea in plain language, pick a
/// loaded text model to interpret it, and get one tailored, editable
/// prompt per registered image model — each with its own Generate
/// button.
struct PromptToModelView: View {
    @EnvironmentObject private var sessions: ModelSessionManager
    @EnvironmentObject private var viewModel: PromptToModelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            intentionBar

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if viewModel.rows.isEmpty {
                Spacer()
                Text("Describe an image and interpret it to see one tailored prompt per image model here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                rowsList
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 480)
        .task {
            viewModel.syncSelectedTextModel()
        }
        .onChange(of: sessions.sessions) { _, _ in viewModel.syncSelectedTextModel() }
    }

    private var header: some View {
        HStack {
            Text("Prompt to Model").font(.headline)
            Spacer()
            if sessions.readySessions.isEmpty {
                Text("Load a text model in Models first").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Interpreter", selection: Binding(
                    get: { viewModel.selectedTextModelID },
                    set: { viewModel.selectedTextModelID = $0 }
                )) {
                    ForEach(sessions.readySessions) { session in
                        Text(session.model.displayName).tag(Optional(session.id))
                    }
                }
                .frame(maxWidth: 260)
                .help("Which loaded text model writes the tailored prompts.")
            }
        }
    }

    private var intentionBar: some View {
        HStack(alignment: .top) {
            TextField("Describe the image you want…", text: Binding(
                get: { viewModel.intention },
                set: { viewModel.intention = $0 }
            ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)

            if viewModel.isInterpreting {
                ProgressView().controlSize(.small).padding(.top, 6)
            }

            Button("Interpret") { Task { await viewModel.interpret() } }
                .disabled(
                    sessions.readySessions.isEmpty
                    || viewModel.isInterpreting
                    || viewModel.intention.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
        }
    }

    private var rowsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(viewModel.rows) { row in
                    rowView(row)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func rowView(_ row: PromptToModelRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.model.displayName).font(.headline)
                Spacer()
                if let image = row.lastGeneratedImage {
                    InteractiveImageView(path: image.localPath)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .help("Generated — also in Images → History.")
                }
                generateButton(row)
            }

            TextEditor(text: Binding(
                get: { row.prompt },
                set: { viewModel.updatePrompt(row.id, to: $0) }
            ))
            .font(.callout)
            .frame(minHeight: 70, maxHeight: 120)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            if let error = row.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func generateButton(_ row: PromptToModelRow) -> some View {
        HStack(spacing: 6) {
            if row.isGenerating {
                CircularProgressView(fraction: row.generationProgress)
                    .frame(width: 16, height: 16)
            }
            Button(row.isGenerating ? "Generating…" : "Generate") {
                Task { await viewModel.generateRow(row.id) }
            }
            .disabled(row.isGenerating || row.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Loads \(row.model.displayName) if needed, generates, and adds it to Images → History.")
        }
    }
}
