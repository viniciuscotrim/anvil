import AnvilCore
import Foundation
import Observation

/// Owns the list of Macs this phone knows about, and finding new ones.
/// Chat's "On Your Mac" source picker (`NativeChatView`) and the Images
/// tab's own connection sheet (`RemoteMacView`) each hold their own
/// separate instance of this type — not a shared one — but both read
/// and write the same underlying `remote_connections.json` via
/// `RemoteMacConnectionStore`, so the *saved* list of Macs never drifts
/// apart between the two; only in-flight, in-memory state (a scan
/// currently running, its progress, what it's found so far) is
/// per-screen.
///
/// Frictionless by design: no IP, no port, ever typed for this to work.
/// `refreshConnections()` first re-checks whatever's already saved (fast:
/// a handful of exact addresses, in parallel), then scans the subnet for
/// anything live and not already saved — safe to call again (pull-to-
/// refresh, reopening a tab): reuses whatever's already there rather
/// than duplicating saved entries.
@MainActor
@Observable
final class RemoteConnectionsViewModel {
    private(set) var connections: [RemoteMacConnection] = []
    /// Which saved connections answered when last checked — `nil` means
    /// "not checked yet this launch", not "offline". Checked first, fast
    /// (a handful of exact host:port pings), before the broader subnet
    /// scan even starts.
    private(set) var reachableConnectionIDs: Set<UUID> = []
    private(set) var isVerifyingSaved = false
    private(set) var isScanning = false
    private(set) var scanProgress: Double = 0
    /// Live servers found on the network that aren't already saved —
    /// each just needs one tap ("Remote") to start using, never typing
    /// an IP or port.
    private(set) var discoveredModels: [DiscoveredMacModel] = []

    @ObservationIgnored
    private let store = RemoteMacConnectionStore()
    /// `refreshConnections()` runs every time this screen's sheet
    /// appears — since each screen holds its own instance (see this
    /// type's own header comment), this cooldown only helps repeatedly
    /// reopening the *same* screen's sheet within the window, not
    /// switching between Chat's and Images' separate ones — but that's
    /// still a real, common case (dismissing and reopening the same
    /// sheet to glance at scan progress) that could otherwise repeat
    /// the *entire* subnet scan every time, worst case tens of seconds
    /// of Bonjour discovery plus a 254-host/20-port fallback sweep, just
    /// to reappear on a screen the user already saw a moment ago. A
    /// short cooldown skips repeating that scan (previous results stay
    /// shown, still filtered against whatever's saved) when the last
    /// one finished too recently to plausibly have changed.
    @ObservationIgnored
    private static let scanCooldown: TimeInterval = 30
    @ObservationIgnored
    private var lastScanDate: Date?

    var textConnections: [RemoteMacConnection] { connections.filter { $0.kind == .text } }
    var imageConnections: [RemoteMacConnection] { connections.filter { $0.kind == .image } }

    func load() {
        connections = store.load()
    }

    /// The whole point: no IP, no port, ever typed for this to work.
    /// Called the moment a tab appears — first re-checks whatever's
    /// already saved, then scans the subnet for anything live and not
    /// already saved.
    func refreshConnections() async {
        load()
        await verifySavedConnections()
        await scanForNewConnections()
    }

    private func verifySavedConnections() async {
        guard !connections.isEmpty else { return }
        isVerifyingSaved = true
        defer { isVerifyingSaved = false }

        await withTaskGroup(of: (UUID, Bool).self) { group in
            for connection in connections {
                group.addTask {
                    guard case .success = await self.testConnection(connection) else {
                        return (connection.id, false)
                    }
                    return (connection.id, true)
                }
            }
            var reachable: Set<UUID> = []
            for await (id, isReachable) in group {
                if isReachable { reachable.insert(id) }
            }
            reachableConnectionIDs = reachable
        }
    }

    private func scanForNewConnections() async {
        let alreadySaved = Set(connections.map { "\($0.host):\($0.port)" })
        if let lastScanDate, Date().timeIntervalSince(lastScanDate) < Self.scanCooldown {
            // Still re-applies the current saved-connections filter —
            // a model connected to since the last scan must disappear
            // from "discovered" immediately, not only after the next
            // full rescan.
            discoveredModels = discoveredModels.filter { !alreadySaved.contains("\($0.host):\($0.port)") }
            return
        }

        isScanning = true
        scanProgress = 0
        defer { isScanning = false }

        let found = await LocalNetworkScanner.scan { [weak self] fraction in
            Task { @MainActor in self?.scanProgress = fraction }
        }
        lastScanDate = Date()
        discoveredModels = found.filter { !alreadySaved.contains("\($0.host):\($0.port)") }
    }

    /// One tap, from a discovered model straight to "in use" — saves it
    /// (so next time it shows up under "Saved", verified, not scanned
    /// for again). Returns the new connection so the caller can select
    /// it right away.
    @discardableResult
    func connect(to discovered: DiscoveredMacModel) -> RemoteMacConnection {
        let connection = RemoteMacConnection(
            displayName: discovered.displayName, host: discovered.host, port: discovered.port, kind: discovered.kind)
        connections.append(connection)
        store.save(connections)
        reachableConnectionIDs.insert(connection.id)
        discoveredModels.removeAll { $0.id == discovered.id }
        return connection
    }

    @discardableResult
    func addConnection(displayName: String, host: String, port: Int, kind: ModelKind) -> RemoteMacConnection {
        let connection = RemoteMacConnection(displayName: displayName, host: host, port: port, kind: kind)
        connections.append(connection)
        store.save(connections)
        return connection
    }

    func deleteConnection(_ connection: RemoteMacConnection) {
        connections.removeAll { $0.id == connection.id }
        store.save(connections)
    }

    /// A cheap reachability check — `GET /v1/models`, the same endpoint
    /// the Mac's own per-model server already answers, so a real
    /// connectivity problem (wrong IP, model unloaded, phone on a
    /// different network/VPN) surfaces before the user ever types a
    /// message expecting a reply.
    func testConnection(_ connection: RemoteMacConnection) async -> Result<Void, Error> {
        guard let baseURL = connection.baseURL else {
            return .failure(RemoteImageClientError.requestFailed("Invalid host/port."))
        }
        do {
            let (_, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("v1/models"))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failure(RemoteImageClientError.requestFailed("No response from \(connection.host):\(connection.port)."))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
