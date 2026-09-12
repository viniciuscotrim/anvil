import AnvilCore
import SwiftUI

/// Reusable pieces of "manage the Macs this phone knows about" — shared
/// by Chat's "On Your Mac" source picker and the Images tab's own
/// connections sheet, so there's exactly one list, one "Add Manually"
/// flow, and one saved-connections store to look at — not two separate,
/// kind-locked screens that made the same Mac look like two different
/// things depending on which tab you opened it from (a real, reported
/// complaint: adding a Mac's text and image connections used to mean
/// two completely separate "Manage Connections" sheets).

/// A discovered-but-not-yet-saved model, with its one-tap "Remote"
/// button straight into use.
struct DiscoveredConnectionRow: View {
    let discovered: DiscoveredMacModel
    let onConnect: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(discovered.displayName).font(.subheadline).lineLimit(1)
                Text("\(discovered.kind == .image ? "Image" : "Text") · \(discovered.host):\(discovered.port)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remote", action: onConnect)
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A saved connection, with a green/gray dot for whether it answered the
/// last reachability check.
struct SavedConnectionRow: View {
    let connection: RemoteMacConnection
    let isReachable: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(isReachable ? .green : .secondary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(connection.displayName).font(.headline)
                    Text(connection.kind == .image ? "· image" : "· text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("\(connection.host):\(connection.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The full "found / saved / add manually" management list — every
/// connection on every Mac this phone knows about, text and image
/// together, in one place. `preferredKind` only steers which section a
/// freshly-discovered/added connection is offered under by default and
/// which one `onSelect` is most likely called for; it never hides the
/// other kind — the whole point is that adding your Mac once, here,
/// covers both its text and image servers.
struct RemoteConnectionsListView: View {
    @ObservedObject var connectionsModel: RemoteConnectionsViewModel
    var preferredKind: ModelKind = .text
    /// Called after a discovered model is connected-to, or a manual one
    /// is added — lets the caller select it immediately.
    var onSelect: (RemoteMacConnection) -> Void = { _ in }
    @State private var isAddingConnection = false

    var body: some View {
        List {
            if !connectionsModel.discoveredModels.isEmpty {
                Section("Found on Your Network") {
                    ForEach(connectionsModel.discoveredModels) { model in
                        DiscoveredConnectionRow(discovered: model) {
                            onSelect(connectionsModel.connect(to: model))
                        }
                    }
                }
            }

            Section("Saved") {
                if connectionsModel.connections.isEmpty {
                    Text("None yet — connect to something found above, or add one manually.")
                        .foregroundStyle(.secondary)
                }
                ForEach(connectionsModel.connections) { connection in
                    Button {
                        onSelect(connection)
                    } label: {
                        SavedConnectionRow(
                            connection: connection,
                            isReachable: connectionsModel.reachableConnectionIDs.contains(connection.id))
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { indexSet in
                    for index in indexSet { connectionsModel.deleteConnection(connectionsModel.connections[index]) }
                }
            }

            Section {
                Button("Add Manually…") { isAddingConnection = true }
            } footer: {
                Text("For a Mac the scan can't see — a different subnet, or a VPN. "
                    + "A Mac with both a text and an image model running needs one entry for each (they're separate servers, separate ports) — add both here.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if connectionsModel.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await connectionsModel.refreshConnections() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingConnection) {
            AddConnectionView(connectionsModel: connectionsModel, kind: preferredKind, onAdd: onSelect)
        }
    }
}

struct AddConnectionView: View {
    @ObservedObject var connectionsModel: RemoteConnectionsViewModel
    var onAdd: (RemoteMacConnection) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var host = ""
    @State private var port: String
    @State private var kind: ModelKind

    /// A host of "0.0.0.0" (or blank/loopback) is the single most common
    /// mistake here — it's the Mac's own *bind* address for "Network"
    /// access (what the Mac listens on), never a real destination
    /// another device can connect to. Caught explicitly with a plain-
    /// language explanation instead of letting it fail later as a
    /// confusing ATS/"secure connection" error with no obvious cause.
    private var hostLooksInvalid: Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "0.0.0.0" || trimmed == "127.0.0.1" || trimmed == "localhost"
    }

    init(connectionsModel: RemoteConnectionsViewModel, kind: ModelKind = .text, onAdd: @escaping (RemoteMacConnection) -> Void = { _ in }) {
        self.connectionsModel = connectionsModel
        self.onAdd = onAdd
        _kind = State(initialValue: kind)
        _port = State(initialValue: kind == .image ? "8200" : "8100")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("On the Mac") {
                    Text("Load a model, open its Server Settings (gear icon), set Access to \"Network\", and note the Port shown there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Connection") {
                    TextField("Name (e.g. Qwen3.5 on Mac)", text: $displayName)
                    TextField("Mac IP address (e.g. 192.168.1.42)", text: $host)
                        .keyboardType(.decimalPad)
                        .autocapitalization(.none)
                    if hostLooksInvalid {
                        Text("That's the Mac's own bind address, not something another device can connect to — "
                            + "use the Mac's actual IP on your Wi-Fi network instead (System Settings ▸ Wi-Fi ▸ Details…, or the top of the discovered-Mac name here).")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    Picker("Kind", selection: $kind) {
                        Text("Text").tag(ModelKind.text)
                        Text("Image").tag(ModelKind.image)
                    }
                    .onChange(of: kind) { _, newKind in
                        // Only nudge the port to that kind's usual
                        // default while it still looks untouched —
                        // never overwrite a port the user already typed.
                        if port == "8100" || port == "8200" {
                            port = newKind == .image ? "8200" : "8100"
                        }
                    }
                }
            }
            .navigationTitle("Add Connection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let portNumber = Int(port) else { return }
                        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let connection = connectionsModel.addConnection(
                            displayName: name.isEmpty ? host : name,
                            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                            port: portNumber,
                            kind: kind
                        )
                        onAdd(connection)
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(port) == nil || hostLooksInvalid)
                }
            }
            .dismissKeyboardOnTap()
        }
    }
}
