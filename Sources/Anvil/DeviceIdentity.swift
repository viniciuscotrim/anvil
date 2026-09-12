import Foundation

/// This Mac's own display name (e.g. "Vinicius's MacBook Pro" — System
/// Settings ▸ General ▸ Sharing ▸ Computer Name), stamped onto a newly
/// created thread/profile/memory's `originDeviceName` so a two-way
/// merge-synced list (`AnvilSyncServer`/`AnvilSyncClient`) can show
/// which device something actually came from instead of blending
/// everything together with no way to tell.
enum DeviceIdentity {
    static var currentName: String {
        Host.current().localizedName ?? "This Mac"
    }
}
