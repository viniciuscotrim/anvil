import Foundation
import Observation

/// Which screen is showing. Chat isn't tied to a specific model anymore
/// — it's an app-level tab that picks among whatever's currently loaded.
@Observable
final class AppRouter {
    enum Screen: Equatable {
        case bootstrap
        /// Search and download — its own tab now, separate from
        /// `modelManager`'s registered-model library. See
        /// `ModelSearchView`'s own header comment.
        case modelSearch
        case modelManager
        case chat
        case images
        case profiles
        case promptToModel
        case code
    }

    var screen: Screen = .bootstrap
}
