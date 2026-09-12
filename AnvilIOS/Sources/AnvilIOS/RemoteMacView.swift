import SwiftUI
import AnvilCore

/// Chat and generate images through a model already loaded on a Mac on
/// the same network — see `RemoteMacViewModel`'s own header comment for
/// why the Mac side needs zero changes for this to work (every loaded
/// model already has a Local-only/Network toggle and its own port).
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
                    emptyState
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
                    Button { isManagingConnections = true } label: { Image(systemName: "network") }
                }
            }
            .sheet(isPresented: $isManagingConnections) { connectionsSheet }
            .task { await viewModel.loadInitialState() }
            .dismissKeyboardOnTap()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "network")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No Mac Connected")
                .font(.headline)
            Text("On the Mac, load a model, then set its Server Settings (the gear icon next to it) to \"Network\" — note the port shown there, then add it here with the Mac's IP address.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Add Connection") { isManagingConnections = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            Spacer()
        }
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
                Text(only.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        }
    }
}

private struct RemoteConnectionsListView: View {
    @ObservedObject var viewModel: RemoteMacViewModel
    @State private var isAddingConnection = false

    var body: some View {
        List {
            if viewModel.connections.isEmpty {
                Text("No connections yet.").foregroundStyle(.secondary)
            }
            ForEach(viewModel.connections) { connection in
                ConnectionRow(connection: connection, viewModel: viewModel)
            }
            .onDelete { indexSet in
                for index in indexSet { viewModel.deleteConnection(viewModel.connections[index]) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { isAddingConnection = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $isAddingConnection) {
            AddConnectionView(viewModel: viewModel)
        }
    }
}

private struct ConnectionRow: View {
    let connection: RemoteMacConnection
    @ObservedObject var viewModel: RemoteMacViewModel
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(connection.displayName).font(.headline)
                Text(connection.kind == .image ? "· image" : "· text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("\(connection.host):\(connection.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(isTesting ? "Testing…" : "Test") {
                    Task {
                        isTesting = true
                        let result = await viewModel.testConnection(connection)
                        isTesting = false
                        switch result {
                        case .success: testResult = "Reachable ✓"
                        case .failure(let error): testResult = error.localizedDescription
                        }
                    }
                }
                .font(.caption)
                .disabled(isTesting)
                if let testResult {
                    Text(testResult).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
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
