import Foundation

// Plain executable entry point (instead of `@main` on AnvilApp) so a
// headless gate check can run and exit before SwiftUI creates any
// window. `App.main()` has a default implementation from SwiftUI's
// protocol extension, so calling it manually here works the same as
// `@main` would for the normal launch path.

let semaphore = DispatchSemaphore(value: 0)
var ranGateCheck = false

Task {
    ranGateCheck = await GateCheck.runPhase2GateIfRequested()
    if !ranGateCheck {
        ranGateCheck = await GateCheck.runPhase3GateIfRequested()
    }
    semaphore.signal()
}
semaphore.wait()

if ranGateCheck {
    exit(0)
} else {
    AnvilApp.main()
}
