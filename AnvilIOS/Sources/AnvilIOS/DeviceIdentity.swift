import UIKit

/// This iPhone's own name (e.g. "Vinicius's iPhone" — Settings ▸
/// General ▸ About ▸ Name), stamped onto a newly created thread/
/// profile/memory's `originDeviceName` so a two-way merge-synced list
/// (`AnvilSyncServer`/`AnvilSyncClient`) can show which device
/// something actually came from instead of blending everything
/// together with no way to tell.
enum DeviceIdentity {
    static var currentName: String {
        UIDevice.current.name
    }
}
