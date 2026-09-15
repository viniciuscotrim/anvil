import AnvilCore
import Foundation
import Observation

/// Remote control for a Mac's own models over `AnvilSyncServer`'s
/// `/v1/anvil/sessions*`/`models` routes — the exact same
/// `ModelSessionManager`/`ImageSessionManager` instances the Mac app's
/// own Models tab already drives, never a separate/parallel state.
/// Loading, unloading, and reconfiguring here does exactly what doing
/// it from the Mac's own gear-icon sheet does.
@MainActor
@Observable
final class RemoteModelsViewModel {
    private(set) var sessions: [ModelSessionWire] = []
    private(set) var allModels: [ModelEntry] = []
    var errorMessage: String?
    private(set) var isBusy = false

    @ObservationIgnored
    private let client = AnvilSyncClient()

    /// Registered but not currently loaded — the "Load" section.
    var unloadedModels: [ModelEntry] {
        let loadedIDs = Set(sessions.map(\.modelID))
        return allModels.filter { !loadedIDs.contains($0.id) }
    }

    func refresh(host: String) async {
        do {
            async let modelsTask = client.models(host: host)
            async let sessionsTask = client.sessions(host: host)
            allModels = try await modelsTask
            sessions = try await sessionsTask
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func load(_ model: ModelEntry, access: ServerAccess, host: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            sessions = try await client.loadModel(modelID: model.id, access: access, host: host)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unload(_ modelID: String, host: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            sessions = try await client.unloadModel(modelID: modelID, host: host)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reloads a loaded model under a different Server Settings access —
    /// switching a model this phone is actively talking to from Network
    /// to Local-only genuinely severs that connection (the server
    /// actually rebinds to loopback-only), the same real consequence
    /// doing it from the Mac's own settings sheet has.
    func setAccess(_ session: ModelSessionWire, access: ServerAccess, host: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            sessions = try await client.updateSessionSettings(modelID: session.modelID, access: access, port: session.port, host: host)
            errorMessage = nil
        } catch {
            // A Network -> Local switch on the very connection this
            // request just went out over can plausibly fail to come
            // back at all (the old connection was already open when the
            // server restarted loopback-only) — not a real error in
            // that case; a manual refresh will show the true state.
            errorMessage = error.localizedDescription
        }
    }
}
