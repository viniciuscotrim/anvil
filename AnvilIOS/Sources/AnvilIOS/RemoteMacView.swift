import SwiftUI
import AnvilCore

/// Chat and generate images through a model already loaded on a Mac on
/// the same network — see `RemoteMacViewModel`'s own header comment for
/// why the Mac side needs zero changes for this to work (every loaded
/// model already has a Local-only/Network toggle and its own port).
///
/// Frictionless by design, not by afterthought: the tab scans for live
/// models the moment it opens (`LocalNetworkScanner`, no IP/port typed
/// anywhere), a discovered one connects with a single "Remote" tap, and
/// it's remembered — reopening checks what's already saved first (fast)
/// before scanning for anything new. Typing a host manually still
/// exists, folded away as a fallback for a network the scan can't see
/// (a different subnet, a VPN), not the primary path.
struct RemoteMacView: View {
    @StateObject private var viewModel = RemoteMacViewModel()
    @State private var mode: Mode = .chat
    @State private var isManagingConnections = false

    private enum Mode: String, CaseIterable, Identifiable {
        case chat = "Chat"
        case images = "Images"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                if viewModel.connections.isEmpty {
                    discoveryState
                } else {
                    switch mode {
                    case .chat: chatBody
                    case .images: imagesBody
                    }
                }
            }
            .navigationTitle("Mac")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isManagingConnections = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "network")
                            if !viewModel.discoveredModels.isEmpty {
                                Circle().fill(.green).frame(width: 8, height: 8).offset(x: 4, y: -4)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $isManagingConnections) { connectionsSheet }
            .task {
                await viewModel.loadInitialState()
                await viewModel.refreshConnections()
            }
            .dismissKeyboardOnTap()
        }
    }

    /// The very first thing anyone sees before any connection exists —
    /// scans right away, no button to press first, and every result is
    /// one tap away from being in use.
    private var discoveryState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 24)
                Image(systemName: "network")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                if viewModel.isScanning {
                    ProgressView(value: viewModel.scanProgress)
                        .frame(width: 160)
                    Text("Scanning your network…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if viewModel.discoveredModels.isEmpty {
                    Text("No Mac Found")
                        .font(.headline)
                    Text("On the Mac, load a model and set its Server Settings (the gear icon next to it) to \"Network\" — it'll show up here automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Scan Again") { Task { await viewModel.refreshConnections() } }
                        .buttonStyle(.bordered)
                } else {
                    Text("Found on Your Network").font(.headline)
                }

                if !viewModel.discoveredModels.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(viewModel.discoveredModels) { discovered in
                            discoveredRow(discovered)
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
        .refreshable { await viewModel.refreshConnections() }
    }

    private func discoveredRow(_ discovered: DiscoveredMacModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(discovered.displayName).font(.subheadline).lineLimit(1)
                Text("\(discovered.kind == .image ? "Image" : "Text") · \(discovered.host):\(discovered.port)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remote") { viewModel.connect(to: discovered) }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Chat

    private var chatBody: some View {
        VStack(spacing: 0) {
            connectionPicker(connections: viewModel.textConnections, selection: $viewModel.selectedTextConnectionID)
            Divider()

            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption).padding(8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(viewModel.currentThread.messages.enumerated()), id: \.element.id) { index, message in
                            bubble(message)
                                .id(message.id)
                            if index == viewModel.currentThread.messages.count - 1,
                                message.role == .assistant, message.content.isEmpty, viewModel.isSending
                            {
                                generatingIndicator
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.currentThread.messages) { _, _ in
                    guard let last = viewModel.currentThread.messages.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .scrollDismissesKeyboard(.interactively)
            }

            Divider()
            HStack {
                TextField("Message…", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .disabled(viewModel.selectedTextConnection == nil)
                if viewModel.isSending {
                    Button("Stop", role: .destructive) { viewModel.stopGeneration() }
                } else {
                    Button("Send") { viewModel.send() }
                        .disabled(viewModel.selectedTextConnection == nil || viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(8)
        }
    }

    private var generatingIndicator: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = viewModel.currentRoundStartedAt.map { max(0, Int(context.date.timeIntervalSince($0))) } ?? 0
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Generating… \(elapsed)s").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 40) }
            if !message.content.isEmpty {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(isUser ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    // MARK: - Images

    private var imagesBody: some View {
        VStack(spacing: 12) {
            connectionPicker(connections: viewModel.imageConnections, selection: $viewModel.selectedImageConnectionID)

            Group {
                if let image = viewModel.lastImage {
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

            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal)
            }
            if viewModel.isGenerating {
                ProgressView().padding(.horizontal)
            }

            TextField("Describe an image…", text: $viewModel.imagePrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .padding(.horizontal)

            Button("Generate") { Task { await viewModel.generateImage() } }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedImageConnection == nil || viewModel.isGenerating || viewModel.imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.bottom, 8)
        }
    }

    private func connectionPicker(connections: [RemoteMacConnection], selection: Binding<UUID?>) -> some View {
        Group {
            if connections.count > 1 {
                Picker("Connection", selection: selection) {
                    ForEach(connections) { connection in
                        Text(connection.displayName).tag(Optional(connection.id))
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)
                .padding(.top, 6)
            } else if let only = connections.first {
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.reachableConnectionIDs.contains(only.id) ? .green : .secondary)
                        .frame(width: 6, height: 6)
                    Text(only.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 6)
                .onAppear { selection.wrappedValue = only.id }
            }
        }
    }

    // MARK: - Connection management

    private var connectionsSheet: some View {
        NavigationStack {
            RemoteConnectionsListView(viewModel: viewModel)
                .navigationTitle("Mac Connections")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isManagingConnections = false }
                    }
                }
                .task { await viewModel.refreshConnections() }
        }
    }
}

private struct RemoteConnectionsListView: View {
    @ObservedObject var viewModel: RemoteMacViewModel
    @State private var isAddingConnection = false

    var body: some View {
        List {
            if !viewModel.discoveredModels.isEmpty {
                Section("Found on Your Network") {
                    ForEach(viewModel.discoveredModels) { discovered in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(discovered.displayName).lineLimit(1)
                                Text("\(discovered.kind == .image ? "Image" : "Text") · \(discovered.host):\(discovered.port)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remote") { viewModel.connect(to: discovered) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }

            Section("Saved") {
                if viewModel.connections.isEmpty {
                    Text("None yet — connect to something found above, or add one manually.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.connections) { connection in
                    ConnectionRow(connection: connection, isReachable: viewModel.reachableConnectionIDs.contains(connection.id))
                }
                .onDelete { indexSet in
                    for index in indexSet { viewModel.deleteConnection(viewModel.connections[index]) }
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
                if viewModel.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await viewModel.refreshConnections() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingConnection) {
            AddConnectionView(viewModel: viewModel)
        }
    }
}

private struct ConnectionRow: View {
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

private struct AddConnectionView: View {
    @ObservedObject var viewModel: RemoteMacViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var host = ""
    @State private var port = "8100"
    @State private var kind: ModelKind = .text

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
                    Picker("Kind", selection: $kind) {
                        Text("Text").tag(ModelKind.text)
                        Text("Image").tag(ModelKind.image)
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
                        viewModel.addConnection(
                            displayName: name.isEmpty ? host : name,
                            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                            port: portNumber,
                            kind: kind
                        )
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(port) == nil)
                }
            }
            .dismissKeyboardOnTap()
        }
    }
}
