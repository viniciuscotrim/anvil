import Foundation

/// Which screen is showing — plain `ObservableObject`, not `@Observable`,
/// so it can be held with `@StateObject` (see the `@State` toolchain
/// note in README). Chat isn't tied to a specific model anymore — it's
/// an app-level tab that picks among whatever's currently loaded.
final class AppRouter: ObservableObject {
    enum Screen: Equatable {
        case bootstrap
        case modelManager
        case chat
        case images
    }

    @Published var screen: Screen = .bootstrap
}
