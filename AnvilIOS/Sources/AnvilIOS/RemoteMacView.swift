import SwiftUI
import AnvilCore

/// Generate images through a model already loaded on a Mac on the same
/// network — see `RemoteMacViewModel`'s own header comment for why the
/// Mac side needs zero changes for this to work (every loaded model
/// already has a Local-only/Network toggle and its own port). Chat's own
/// "talk to a Mac instead of on-device" path lives in `NativeChatView`'s
/// source menu now, not a second chat screen here — see that view's
/// header comment for why the two were merged.
///
/// Frictionless by design: the tab scans for live models the moment it
/// opens (`LocalNetworkScanner`, no IP/port typed anywhere), a
/// discovered one connects with a single "Remote" tap, and it's
/// remembered — reopening checks what's already saved first (fast)
/// before scanning for anything new. Typing a host manually still
/// exists, folded away as a fallback for a network the scan can't see
/// (a different subnet, a VPN), not the primary path.
struct RemoteMacView: View {
    @StateObject private var imagesModel = RemoteMacViewModel()
    @StateObject private var connectionsModel = RemoteConnectionsViewModel()
    @State private var isManagingConnections = false

    private var selectedConnection: RemoteMacConnection? {
        connectionsModel.imageConnections.first { $0.id == imagesModel.selectedImageConnectionID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if connectionsModel.imageConnections.isEmpty {
                    discoveryState
                } else {
                    imagesBody
                }
            }
            .navigationTitle("Mac")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isManagingConnections = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "network")
                            if !connectionsModel.discoveredModels.filter({ $0.kind == .image }).isEmpty {
                                Circle().fill(.green).frame(width: 8, height: 8).offset(x: 4, y: -4)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $isManagingConnections) { connectionsSheet }
            .task {
                connectionsModel.load()
                if imagesModel.selectedImageConnectionID == nil {
                    imagesModel.selectedImageConnectionID = connectionsModel.imageConnections.first?.id
                }
                await connectionsModel.refreshConnections()
            }
            .dismissKeyboardOnTap()
        }
    }

    /// The very first thing anyone sees before any image connection
    /// exists — scans right away, no button to press first, and every
    /// result is one tap away from being in use.
    private var discoveryState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 24)
                Image(systemName: "network")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                let discoveredImages = connectionsModel.discoveredModels.filter { $0.kind == .image }

                if connectionsModel.isScanning {
                    ProgressView(value: connectionsModel.scanProgress)
                        .frame(width: 160)
                    Text("Scanning your network…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if discoveredImages.isEmpty {
                    Text("No Mac Found")
                        .font(.headline)
                    Text("On the Mac, load an image model and set its Server Settings (the gear icon next to it) to \"Network\" — it'll show up here automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Scan Again") { Task { await connectionsModel.refreshConnections() } }
                        .buttonStyle(.bordered)
                } else {
                    Text("Found on Your Network").font(.headline)
                }

                if !discoveredImages.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(discoveredImages) { discovered in
                            DiscoveredConnectionRow(discovered: discovered) {
                                imagesModel.selectedImageConnectionID = connectionsModel.connect(to: discovered).id
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                Button("Enter an Address Manually") { isManagingConnections = true }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Spacer(minLength: 24)
            }
        }
        .refreshable { await connectionsModel.refreshConnections() }
    }

    // MARK: - Images

    private var imagesBody: some View {
        VStack(spacing: 12) {
            connectionPicker

            Group {
                if let image = imagesModel.lastImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack {
                        Spacer()
                        Image(systemName: "photo").font(.system(size: 44)).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal)

            if let error = imagesModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal)
            }
            if imagesModel.isGenerating {
                ProgressView().padding(.horizontal)
            }

            TextField("Describe an image…", text: $imagesModel.imagePrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .padding(.horizontal)

            Button("Generate") { Task { await imagesModel.generateImage(using: selectedConnection) } }
                .buttonStyle(.borderedProminent)
                .disabled(selectedConnection == nil || imagesModel.isGenerating || imagesModel.imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.bottom, 8)
        }
    }

    private var connectionPicker: some View {
        Group {
            if connectionsModel.imageConnections.count > 1 {
                Picker("Connection", selection: $imagesModel.selectedImageConnectionID) {
                    ForEach(connectionsModel.imageConnections) { connection in
                        Text(connection.displayName).tag(Optional(connection.id))
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)
                .padding(.top, 6)
            } else if let only = connectionsModel.imageConnections.first {
                HStack(spacing: 4) {
                    Circle()
                        .fill(connectionsModel.reachableConnectionIDs.contains(only.id) ? .green : .secondary)
                        .frame(width: 6, height: 6)
                    Text(only.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 6)
                .onAppear { imagesModel.selectedImageConnectionID = only.id }
            }
        }
    }

    // MARK: - Connection management

    private var connectionsSheet: some View {
        NavigationStack {
            RemoteConnectionsListView(connectionsModel: connectionsModel, kind: .image) { connection in
                imagesModel.selectedImageConnectionID = connection.id
                isManagingConnections = false
            }
            .navigationTitle("Mac Connections")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isManagingConnections = false }
                }
            }
        }
    }
}
