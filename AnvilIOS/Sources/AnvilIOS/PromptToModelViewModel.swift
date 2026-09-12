import AnvilCore
import Foundation

/// "Prompt to Model" on iOS: type a plain-language image idea, have
/// whichever text model is already loaded in Chat turn it into one
/// tailored, editable image-generation prompt, then generate it through
/// the on-device image engine.
///
/// The Mac app's version fans one idea out into a row per *registered*
/// image model (mflux, potentially several different weight sets, each
/// its own local server). `NativeImageEngine` doesn't have an
/// equivalent yet — it drives a single, fixed on-device preset (SDXL
/// Turbo; see its own header comment) rather than loading arbitrary
/// registered image models — so there's only one row to tailor a
/// prompt for here. Multi-model fan-out can come back once
/// `NativeImageEngine` supports switching between presets/models.
@Observable @MainActor
final class PromptToModelViewModel {
    var intention: String = ""
    var interpretedPrompt: String = ""
    var isInterpreting = false
    var errorMessage: String?

    /// Asks `chatEngine`'s already-loaded model to write one tailored
    /// prompt from `intention` — a one-off request via
    /// `NativeChatEngine.respondOnce`, isolated from the ongoing Chat
    /// conversation.
    func interpret(using chatEngine: NativeChatEngine) async {
        let trimmed = intention.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Describe the image you want first."
            return
        }
        guard chatEngine.isLoaded else {
            errorMessage = "Load a text model in Chat first — it writes the tailored prompt."
            return
        }

        errorMessage = nil
        isInterpreting = true
        defer { isInterpreting = false }

        let instruction = """
            You turn a user's plain-language image idea into a single, detailed, effective \
            image-generation prompt for a Stable Diffusion model.

            User's idea: "\(trimmed)"

            Write the prompt in English regardless of what language the idea was written in — \
            richly descriptive, the way a skilled prompt engineer would. Respond with ONLY the \
            prompt text — no quotes, no markdown, no explanation before or after.
            """

        do {
            let reply = try await chatEngine.respondOnce(to: instruction)
            interpretedPrompt = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
