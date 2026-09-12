import AnvilCore
import Foundation

/// "Prompt to Model" on iOS: type a plain-language image idea, have
/// whichever text model is already loaded in Chat turn it into one
/// tailored, editable image-generation prompt, then generate it through
/// the on-device image engine.
///
/// The Mac app's version fans one idea out into a row per *registered*
/// image model — mflux runs each as its own separate process, so
/// holding several loaded at once costs it nothing extra. `NativeImageEngine`
/// can now load any registered image model too (see
/// `StableDiffusionModelLoader`), not just its built-in SDXL Turbo
/// preset, but still only one at a time in-process — several
/// multi-gigabyte diffusion models resident simultaneously is a real
/// way to get OOM-killed on a phone that a Mac's per-model subprocess
/// isolation doesn't have to worry about. So there's still only one row
/// here: whichever image model is currently loaded (in Images or via
/// this screen's own Generate), not a fan-out across the whole registry.
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
