import Testing
@testable import AnvilCore

@Suite("RequirementsManager")
struct RequirementsManagerTests {
    private actor Recorder {
        private(set) var installedIDs: [String] = []
        func record(_ id: String) { installedIDs.append(id) }
    }

    private struct FakeDependency: Dependency {
        let id: String
        let displayName: String
        let satisfied: Bool
        let recorder: Recorder

        func isSatisfied() async -> Bool { satisfied }

        func install(onProgress: @escaping @Sendable (InstallProgress) -> Void) async throws {
            onProgress(InstallProgress(message: "Installing \(displayName)…"))
            await recorder.record(id)
        }
    }

    /// Encodes the Phase 1 gate: picking a text model must install mlx-lm
    /// and must NOT touch mflux or mlx-audio.
    @Test @MainActor
    func ensureInstallsOnlyTheRequestedDependency() async throws {
        let recorder = Recorder()
        let manager = RequirementsManager()
        let textEngine = FakeDependency(id: "mlx-lm", displayName: "Text", satisfied: false, recorder: recorder)

        let ok = await manager.ensure(textEngine)

        #expect(ok)
        let installed = await recorder.installedIDs
        #expect(installed == ["mlx-lm"])
        #expect(!installed.contains("mflux"))
        #expect(!installed.contains("mlx-audio"))
    }

    @Test @MainActor
    func ensureSkipsInstallWhenAlreadySatisfied() async throws {
        let recorder = Recorder()
        let manager = RequirementsManager()
        let dependency = FakeDependency(id: "huggingface-client", displayName: "HF Client", satisfied: true, recorder: recorder)

        let ok = await manager.ensure(dependency)

        #expect(ok)
        let installed = await recorder.installedIDs
        #expect(installed.isEmpty)
    }

    @Test @MainActor
    func ensureCachesSuccessAndDoesNotReinstall() async throws {
        let recorder = Recorder()
        let manager = RequirementsManager()
        let dependency = FakeDependency(id: "mlx-lm", displayName: "Text", satisfied: false, recorder: recorder)

        _ = await manager.ensure(dependency)
        _ = await manager.ensure(dependency)

        let installed = await recorder.installedIDs
        #expect(installed == ["mlx-lm"], "second ensure() call must not reinstall")
    }

    @Test @MainActor
    func ensureSurfacesInstallFailureWithoutCaching() async throws {
        struct FailingDependency: Dependency {
            let id = "broken"
            let displayName = "Broken"
            func isSatisfied() async -> Bool { false }
            func install(onProgress: @escaping @Sendable (InstallProgress) -> Void) async throws {
                throw DependencyError.installFailed("simulated failure")
            }
        }
        let manager = RequirementsManager()

        let ok = await manager.ensure(FailingDependency())

        #expect(!ok)
        #expect(manager.lastError != nil)
        #expect(!manager.isInstalling)
    }
}
