import Foundation

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

/// Installs only when the user selects a text/chat model.
public struct TextModelRuntimeDependency: Dependency {
    public let id = "mlx-lm"
    public let displayName = "Text generation"

    private let python = PythonEnvironment()

    public init() {}

    public func isSatisfied() async -> Bool {
        await python.isPackageInstalled("mlx_lm")
    }

    public func install(onProgress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        onProgress(InstallProgress(message: "Setting up text generation…"))
        try await python.pipInstall(["mlx-lm"])
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
