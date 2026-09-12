import AnvilCore
import SwiftUI

/// Manage a Mac's own models from the iPhone — see what's registered,
/// load/unload, and change a loaded one's Server Settings (access/port),
/// all through `AnvilSyncServer`'s model-management routes. Every action
/// here does exactly what doing it from the Mac's own gear-icon sheet
/// does: switching a loaded model from Network to Local-only really
/// rebinds its server to loopback-only, so this phone (or any other
/// device) genuinely loses the connection, not just a label change.
struct RemoteModelsView: View {
    let host: String
    @StateObject private var viewModel = RemoteModelsViewModel()

    var body: some View {
        NavigationStack {
            List {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red).font(.caption)
                }

                Section("Loaded on This Mac") {
                    if viewModel.sessions.isEmpty {
                        Text("Nothing loaded right now.").foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.sessions) { session in
                        sessionRow(session)
                    }
                }

                Section("Registered") {
                    if viewModel.unloadedModels.isEmpty {
                        Text("Nothing else registered on this Mac.").foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.unloadedModels) { model in
                        modelRow(model)
                    }
                }
            }
            .navigationTitle("Mac Models")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await viewModel.refresh(host: host) } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .refreshable { await viewModel.refresh(host: host) }
            .task { await viewModel.refresh(host: host) }
        }
    }

    private func sessionRow(_ session: ModelSessionWire) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName).font(.headline).lineLimit(1)
                Text("\(session.kind == .image ? "Image" : "Text") · \(session.access.label) · port \(session.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if session.statusLabel == "failed", let detail = session.statusDetail {
                    Text(detail).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if session.statusLabel == "loading" {
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                if session.access == .localOnly {
                    Button("Switch to Network") {
                        Task { await viewModel.setAccess(session, access: .network, host: host) }
                    }
                } else {
                    Button("Switch to Local Only") {
                        Task { await viewModel.setAccess(session, access: .localOnly, host: host) }
                    }
                }
                Divider()
                Button("Unload", role: .destructive) {
                    Task { await viewModel.unload(session.modelID, host: host) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(viewModel.isBusy)
        }
    }

    private func modelRow(_ model: ModelEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).font(.subheadline).lineLimit(1)
                Text(model.kind == .image ? "Image" : "Text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Load (Local Only)") {
                    Task { await viewModel.load(model, access: .localOnly, host: host) }
                }
                Button("Load (Network)") {
                    Task { await viewModel.load(model, access: .network, host: host) }
                }
            } label: {
                Text("Load").font(.callout)
            }
            .disabled(viewModel.isBusy)
        }
    }
}
