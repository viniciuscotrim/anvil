import Foundation
import AnvilCore

/// Which screen is showing — plain `ObservableObject`, not `@Observable`,
/// so it can be held with `@StateObject` (see the `@State` toolchain
/// note in README).
final class AppRouter: ObservableObject {
    enum Screen: Equatable {
        case bootstrap
        case modelManager
        case chat(ModelEntry)
    }

    @Published var screen: Screen = .bootstrap
}
