import Foundation

// macOS-only: every concrete Dependency here is built around
// UVBootstrapper/PythonEnvironment, both Process-based and thus
// macOS-only themselves. The `Dependency` protocol they conform to
// stays cross-platform (see Dependency.swift) — iOS just needs its
// own concrete dependencies (e.g. downloading an mlx-swift model)
// rather than a port of these.
#if os(macOS)

/// Enough to browse Hugging Face and pick a model. This is the *only*
/// thing that installs on first launch — everything below is lazy.
public struct HuggingFaceClientDependency: Dependency {
    public let id = "huggingface-client"
    public let displayName = "Model browser"

    private let uv = UVBootstrapper()
    private let python = PythonEnvironment()

    public init() {}

    public func isSatisfied() async -> Bool {
        guard uv.isInstalled() else { return false }
        return await python.isPackageInstalled("huggingface_hub")
    }

    public func install(onProgress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        try await uv.install(onProgress: onProgress)
        try await python.createVenvIfNeeded(onProgress: onProgress)
        onProgress(InstallProgress(message: "Setting up model browser…"))
        try await python.pipInstall(["huggingface_hub"])
    }
}

/// Installs only when the user selects a text/chat model running on MLX.
public struct TextModelRuntimeDependency: Dependency {
    public let id = "mlx-lm"
    public let displayName = "Text generation (MLX)"

    private let python = PythonEnvironment()

    public init() {}

    public func isSatisfied() async -> Bool {
        await python.isPackageInstalled("mlx_lm")
    }

    public func install(onProgress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        onProgress(InstallProgress(message: "Setting up MLX text generation…"))
        try await python.pipInstall(["mlx-lm"])
    }
}

/// Installs only when the user selects a GGUF text model running via llama.cpp.
public struct LlamaCppRuntimeDependency: Dependency {
    public let id = "llama-cpp-server"
    public let displayName = "GGUF generation (llama.cpp)"

    private let python = PythonEnvironment()

    public init() {}

    public func isSatisfied() async -> Bool {
        await python.isPackageInstalled("llama_cpp")
    }

    public func install(onProgress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        onProgress(InstallProgress(message: "Setting up llama.cpp runtime (Metal enabled)…"))
        // Install with Metal GPU support enabled for Apple Silicon
        try await python.pipInstall([
            "llama-cpp-python",
            "--extra-index-url", "https://abetlen.github.io/llama-cpp-python/whl/metal"
        ])
    }
}

/// Installs only when the user selects an image-capable model.
public struct ImageModelRuntimeDependency: Dependency {
    public let id = "mflux"
    public let displayName = "Image generation"

    private let python = PythonEnvironment()

    public init() {}

    public func isSatisfied() async -> Bool {
        await python.isPackageInstalled("mflux")
    }

    public func install(onProgress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        onProgress(InstallProgress(message: "Setting up image generation…"))
        try await python.pipInstall(["mflux"])
    }
}

/// Installs only when `ContextShiftCoordinator` actually starts
/// watching (a text model has to be loaded first) — the packages
/// `ContextShiftScript`'s RAG phase needs. `mlx_embeddings` is tried
/// first for both embedding models, but confirmed directly (see
/// `ContextShiftScript`'s own header comment) that neither
/// nomic-embed-text-v2-moe nor CodeRankEmbed's `nomic_bert`
/// architecture is one it supports yet, so `sentence-transformers`
/// (`einops` is a hard runtime requirement of nomic's own
/// `trust_remote_code` modeling file) is what actually runs today,
/// on PyTorch/MPS rather than pure MLX — still Apple Silicon GPU
/// acceleration, just not the `mlx` package, for this one phase.
public struct ContextShiftRuntimeDependency: Dependency {
    public let id = "context-shift"
    public let displayName = "Conversation compaction"

    private let python = PythonEnvironment()

    public init() {}

    public func isSatisfied() async -> Bool {
        guard await python.isPackageInstalled("psutil") else { return false }
        guard await python.isPackageInstalled("sentence_transformers") else { return false }
        guard await python.isPackageInstalled("einops") else { return false }
        return true
    }

    public func install(onProgress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        onProgress(InstallProgress(message: "Setting up conversation compaction…"))
        try await python.pipInstall(["psutil", "mlx-embeddings", "sentence-transformers", "einops"])
    }
}

/// Installs only when the user enables voice chat / taps the mic.
public struct VoiceRuntimeDependency: Dependency {
    public let id = "mlx-audio"
    public let displayName = "Voice chat"

    private let python = PythonEnvironment()

    public init() {}

    public func isSatisfied() async -> Bool {
        await python.isPackageInstalled("mlx_audio")
    }

    public func install(onProgress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        onProgress(InstallProgress(message: "Setting up voice chat…"))
        try await python.pipInstall(["mlx-audio"])
    }
}

#endif
