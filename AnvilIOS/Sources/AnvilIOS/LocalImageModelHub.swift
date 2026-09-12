import AnvilCore
import Foundation
import Hub

/// Makes an already-downloaded, registered image model resolvable
/// through the vendored `StableDiffusion` library's own
/// `resolve(hub:configuration:key:)` — which always looks a file up via
/// `hub.localRepoLocation(Hub.Repo(id: configuration.id))` — without
/// forking that lookup code or copying gigabytes of weights into a
/// second location.
///
/// `HubApi.localRepoLocation` builds `downloadBase/models/<repo id>`,
/// with the id's own "/" becoming a real nested path component
/// (confirmed directly — `URL.appending(component:)` does not
/// percent-encode a slash the way it might look like it should).
/// `HFRepoDownloader` instead stores a model flat, as
/// `<modelsRoot>/<org>--<repo>` (see its own `sanitize`), so the two
/// layouts never coincide on their own. One symlink per model — from
/// the path the library expects to the path the registry actually
/// uses — closes that gap for exactly as many models as have ever been
/// loaded here, cheaply and reversibly (removing a model still removes
/// the same real files; the dangling symlink left behind is harmless
/// and gets repaired or removed the next time this runs for that id).
enum LocalImageModelHub {
    private static var linksRoot: URL {
        RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("imageModelHubLinks", isDirectory: true)
    }

    /// A `HubApi` pointed at the private links directory above. Only
    /// ever used for its `localRepoLocation` path-building — the local-
    /// loading path never calls `hub.snapshot`/`download`, so no
    /// network client work happens just from constructing this.
    static func hub() -> HubApi {
        HubApi(downloadBase: linksRoot)
    }

    /// Ensures `hub().localRepoLocation(Hub.Repo(id: entry.id))`
    /// resolves to `entry`'s real files, creating or repairing the
    /// symlink if needed. Safe to call every time before loading — a
    /// no-op once the link already points at the right place.
    static func link(for entry: ModelEntry) throws {
        let destination = hub().localRepoLocation(Hub.Repo(id: entry.id))
        let real = URL(fileURLWithPath: entry.localPath).standardizedFileURL

        let fm = FileManager.default
        if let existingTarget = try? fm.destinationOfSymbolicLink(atPath: destination.path),
            URL(fileURLWithPath: existingTarget).standardizedFileURL == real
        {
            return
        }
        try? fm.removeItem(at: destination)
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: destination, withDestinationURL: real)
    }
}
