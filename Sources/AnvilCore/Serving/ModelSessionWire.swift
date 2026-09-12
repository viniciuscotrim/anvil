import Foundation

/// The wire shape for a loaded session, as `AnvilSyncServer`'s
/// `/v1/anvil/sessions*` routes send it — deliberately not `#if
/// os(macOS)` like `AnvilSyncServer`/`ModelSessionManager` themselves,
/// so iOS can decode it too (it only ever *receives* this shape over
/// HTTP; it never runs the server or the session managers it describes).
/// `ModelSessionManager.Session`/`ImageSessionManager.Session` aren't
/// `Codable` themselves (their `Status` carries an associated `String`
/// only for `.failed`), so this flattens that into two plain fields.
public struct ModelSessionWire: Codable, Sendable, Identifiable {
    public let modelID: String
    public let displayName: String
    public let kind: ModelKind
    public let port: Int
    public let access: ServerAccess
    public let statusLabel: String
    public let statusDetail: String?
    public var id: String { modelID }

    public init(
        modelID: String, displayName: String, kind: ModelKind, port: Int,
        access: ServerAccess, statusLabel: String, statusDetail: String?
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.kind = kind
        self.port = port
        self.access = access
        self.statusLabel = statusLabel
        self.statusDetail = statusDetail
    }
}
