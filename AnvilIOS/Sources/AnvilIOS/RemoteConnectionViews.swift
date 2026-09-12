import AnvilCore
import SwiftUI

/// Reusable pieces of "manage the Macs this phone knows about" — shared
/// by Chat's "On Your Mac" source picker and the Images tab's own
/// connections sheet, so there's exactly one look for this instead of
/// two screens that could drift apart.

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

/// The full "found / saved / add manually" management list, filtered to
/// one connection `kind` (a Chat source picker only wants `.text`, the
/// Images tab only wants `.image`).
struct RemoteConnectionsListView: View {
    @ObservedObject var connectionsModel: RemoteConnectionsViewModel
    let kind: ModelKind
    /// Called after a discovered model is connected-to, or a manual one
    /// is added — lets the caller select it immediately.
    var onSelect: (RemoteMacConnection) -> Void = { _ in }
    @State private var isAddingConnection = false

    private var discovered: [DiscoveredMacModel] {
        connectionsModel.discoveredModels.filter { $0.kind == kind }
    }
    private var saved: [RemoteMacConnection] {
        kind == .text ? connectionsModel.textConnections : connectionsModel.imageConnections
    }

    var body: some View {
        List {
            if !discovered.isEmpty {
                Section("Found on Your Network") {
                    ForEach(discovered) { model in
                        DiscoveredConnectionRow(discovered: model) {
                            onSelect(connectionsModel.connect(to: model))
                        }
                    }
                }
            }

            Section("Saved") {
                if saved.isEmpty {
                    Text("None yet — connect to something found above, or add one manually.")
                        .foregroundStyle(.secondary)
                }
                ForEach(saved) { connection in
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
                    for index in indexSet { connectionsModel.deleteConnection(saved[index]) }
                }
            }

            Section {
                Button("Add Manually…") { isAddingConnection = true }
            } footer: {
                Text("For a Mac the scan can't see — a different subnet, or a VPN.")
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
            AddConnectionView(connectionsModel: connectionsModel, kind: kind, onAdd: onSelect)
        }
    }
}

struct AddConnectionView: View {
    @ObservedObject var connectionsModel: RemoteConnectionsViewModel
    let kind: ModelKind
    var onAdd: (RemoteMacConnection) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var host = ""
    @State private var port: String

    init(connectionsModel: RemoteConnectionsViewModel, kind: ModelKind, onAdd: @escaping (RemoteMacConnection) -> Void = { _ in }) {
        self.connectionsModel = connectionsModel
        self.kind = kind
        self.onAdd = onAdd
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
                    TextField("Mac IP address", text: $host)
                        .keyboardType(.decimalPad)
                        .autocapitalization(.none)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
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
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(port) == nil)
                }
            }
            .dismissKeyboardOnTap()
        }
    }
}
