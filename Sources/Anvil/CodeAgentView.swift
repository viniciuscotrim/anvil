import SwiftUI
import AppKit
import AnvilCore
import UniformTypeIdentifiers

/// "Code" — the same on-device chat, but able to read/write files and
/// run terminal commands in a folder you pick, gated by the feature
/// toggles and permission level in the sidebar. Structurally mirrors
/// `ChatView` (header with model picker, message list, input bar,
/// collapsible sidebar) with tool activity rendered inline instead of
/// hidden, and a pending-approval banner / manual-mode proposal panel
/// `ChatView` has no equivalent of.
struct CodeAgentView: View {
    @EnvironmentObject private var sessions: ModelSessionManager
    @EnvironmentObject private var codeAgent: CodeAgentViewModel
    @State private var isSidebarOpen = true
    @State private var isChoosingFolder = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()

                if sessions.readySessions.isEmpty {
                    emptyState
                } else if codeAgent.messages.isEmpty {
                    Spacer()
                    Text("Ask it to read, write, or run something in \(workingFolderLabel).")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                } else {
                    messageList
                }

                if let approval = codeAgent.pendingApproval {
                    approvalBanner(approval)
                }

                if let error = codeAgent.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.top, 4)
                }

                Divider()
                inputBar
            }
            .frame(minWidth: 520, minHeight: 520)

            if isSidebarOpen {
                Divider()
                sidebar
                    .frame(width: 300)
            }
        }
        .task { await codeAgent.loadInitialState() }
        .onChange(of: sessions.sessions) { _, _ in codeAgent.syncSelectedModel() }
    }

    private var workingFolderLabel: String {
        codeAgent.workingDirectoryPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "no folder yet"
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            if sessions.readySessions.isEmpty {
                Text("Code").font(.headline)
            } else {
                Picker("", selection: Binding(
                    get: { codeAgent.selectedModelID },
                    set: { codeAgent.selectedModelID = $0 }
                )) {
                    ForEach(sessions.readySessions) { session in
                        Text(session.model.displayName).tag(Optional(session.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            Spacer()

            Text(workingFolderLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                isSidebarOpen.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No models loaded")
                .font(.headline)
            Text("Load a model from the Models tab first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(codeAgent.messages) { message in
                        row(for: message)
                            .id(message.id)
                    }
                    if codeAgent.isSending {
                        ProgressView().controlSize(.small).padding(.leading, 4)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: codeAgent.messages) { _, _ in
                guard let last = codeAgent.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(for message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            bubble(text: message.content, isUser: true)
        case .assistant:
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                ForEach(toolCalls) { call in
                    toolCallRow(call)
                }
                if !message.content.isEmpty {
                    bubble(text: message.content, isUser: false)
                }
            } else if !message.content.isEmpty {
                bubble(text: message.content, isUser: false)
            }
        case .tool:
            toolResultRow(message)
        case .system:
            EmptyView()
        }
    }

    private func bubble(text: String, isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(text)
                .textSelection(.enabled)
                .padding(10)
                .background(isUser ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private func toolCallRow(_ call: ChatMessage.ToolCall) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: call.name))
                .foregroundStyle(.secondary)
            Text(summary(for: call))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.leading, 4)
    }

    private func toolResultRow(_ message: ChatMessage) -> some View {
        ScrollView {
            Text(message.content)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 160)
        .background(Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.leading, 20)
    }

    private func icon(for toolName: String) -> String {
        switch toolName {
        case ChatTool.readFile.name: return "doc.text"
        case ChatTool.listDirectory.name: return "folder"
        case ChatTool.writeFile.name: return "square.and.pencil"
        case ChatTool.runTerminalCommand.name: return "terminal"
        default: return "wrench"
        }
    }

    private func summary(for call: ChatMessage.ToolCall) -> String {
        struct PathArgs: Decodable { let path: String }
        struct CommandArgs: Decodable { let command: String }
        let data = call.argumentsJSON.data(using: .utf8)
        switch call.name {
        case ChatTool.runTerminalCommand.name:
            if let data, let args = try? JSONDecoder().decode(CommandArgs.self, from: data) {
                return "$ \(args.command)"
            }
        default:
            if let data, let args = try? JSONDecoder().decode(PathArgs.self, from: data) {
                return "\(call.name)(\(args.path))"
            }
        }
        return call.name
    }

    // MARK: - Approval banner

    private func approvalBanner(_ approval: CodeAgentViewModel.PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Approve this?").font(.headline)
            Text(approval.summary)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Deny", role: .destructive) { codeAgent.denyPending() }
                Button("Approve") { codeAgent.approvePending() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack {
            TextField("Message…", text: Binding(
                get: { codeAgent.inputText },
                set: { codeAgent.inputText = $0 }
            ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { Task { await codeAgent.send() } }
                .disabled(sessions.readySessions.isEmpty || codeAgent.pendingApproval != nil)

            Button("Send") { Task { await codeAgent.send() } }
                .disabled(
                    sessions.readySessions.isEmpty
                    || codeAgent.isSending
                    || codeAgent.pendingApproval != nil
                    || codeAgent.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
        }
        .padding()
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        Form {
            Section("Conversation") {
                Button("New Thread") { codeAgent.newThread() }
                if !codeAgent.allThreads.isEmpty {
                    Picker("History", selection: Binding(
                        get: { codeAgent.currentThread.id },
                        set: { id in
                            if let thread = codeAgent.allThreads.first(where: { $0.id == id }) {
                                codeAgent.selectThread(thread)
                            }
                        }
                    )) {
                        ForEach(codeAgent.allThreads) { thread in
                            Text(thread.title).tag(thread.id)
                        }
                    }
                }
                Button("Clear Conversation") { codeAgent.clearCurrentConversation() }
                    .disabled(codeAgent.messages.isEmpty)
            }

            Section("Working Folder") {
                Text(codeAgent.workingDirectoryPath ?? "None chosen yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack {
                    Button("Choose…") { isChoosingFolder = true }
                        .fileImporter(
                            isPresented: $isChoosingFolder,
                            allowedContentTypes: [.folder]
                        ) { result in
                            if case .success(let url) = result {
                                codeAgent.chooseWorkingDirectory(url)
                            }
                        }
                    if codeAgent.workingDirectoryPath != nil {
                        Button("Clear") { codeAgent.clearWorkingDirectory() }
                    }
                }
                Toggle("Allow full disk access", isOn: Binding(
                    get: { codeAgent.allowFullDiskAccess },
                    set: { codeAgent.allowFullDiskAccess = $0 }
                ))
                .help("Lets file/terminal tools reach anywhere your user account can, not just the working folder above. Off by default — turn on only if you mean it.")
            }

            Section("Features") {
                ForEach(CodeAgentFeature.allCases) { feature in
                    Toggle(isOn: Binding(
                        get: { codeAgent.enabledFeatures.contains(feature) },
                        set: { isOn in
                            if isOn {
                                codeAgent.enabledFeatures.insert(feature)
                            } else {
                                codeAgent.enabledFeatures.remove(feature)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.label)
                            Text(feature.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Permission Level") {
                Picker("", selection: Binding(
                    get: { codeAgent.permissionLevel },
                    set: { codeAgent.permissionLevel = $0 }
                )) {
                    ForEach(CodeAgentPermissionLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(codeAgent.permissionLevel.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let proposal = codeAgent.manualProposal {
                Section("Prepared — Manual Mode") {
                    manualProposalView(proposal)
                }
            }

            Section("Generation") {
                LabeledContent("Max Tokens") {
                    TextField("Unlimited", text: Binding(
                        get: { codeAgent.settings.maxTokens.map(String.init) ?? "" },
                        set: { codeAgent.settings.maxTokens = Int($0.trimmingCharacters(in: .whitespaces)) }
                    ))
                    .frame(width: 80)
                }
                LabeledContent("Temperature") {
                    TextField("", value: Binding(
                        get: { codeAgent.settings.temperature },
                        set: { codeAgent.settings.temperature = $0 }
                    ), format: .number)
                    .frame(width: 80)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func manualProposalView(_ proposal: CodeAgentViewModel.ManualProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch proposal {
            case .writeFile(let path, let content):
                Text(path).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                Button("Copy Contents") { copyToPasteboard(content) }
            case .runTerminalCommand(let command):
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy Command") { copyToPasteboard(command) }
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
