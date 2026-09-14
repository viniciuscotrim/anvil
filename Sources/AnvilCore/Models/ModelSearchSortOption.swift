import Foundation

/// How Search's results are ordered — requested live: "Na aba de
/// busca, me dar opcões de ordenação dos resultados em todas as
/// plataformas por tamanho, quantidade de downloads, data de
/// atualização/pulicação." One shared enum backs the sort control on
/// both Mac and iOS, and applies to whichever catalog (Hugging Face,
/// CivitAI, Draw Things) is currently selected — the same choices
/// everywhere, not a per-source set.
public enum ModelSearchSortOption: String, CaseIterable, Identifiable, Sendable {
    /// Each catalog's own existing order (Hugging Face and CivitAI both
    /// already ask their API to sort by downloads; Draw Things' own
    /// merge of curated + Hugging Face results does the same locally),
    /// with results that fit this device's RAM bubbled ahead of ones
    /// that don't (`ModelSizeClass.sortedByRunnability`) — unchanged
    /// default behavior from before this option existed.
    case relevance
    case size
    case downloads
    case updated

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .relevance: return "Relevance"
        case .size: return "Size"
        case .downloads: return "Downloads"
        case .updated: return "Updated"
        }
    }
}

public extension Array {
    /// Sorts descending by a `Comparable` key that may not apply to
    /// every element — the shared building block behind every
    /// "Size"/"Downloads"/"Updated" sort in Search. An element with no
    /// value for `key` always sorts last (there's nothing to rank it
    /// by), on both sides: two such elements keep their existing
    /// relative order (Swift's `sorted` is stable), rather than being
    /// reshuffled against each other for no reason.
    func sortedDescending<T: Comparable>(by key: (Element) -> T?) -> [Element] {
        sorted { lhs, rhs in
            switch (key(lhs), key(rhs)) {
            case let (l?, r?): return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return false
            }
        }
    }
}
