import Foundation

/// STAC API conformance classes, mirroring `pystac_client.conformance.ConformanceClasses`.
///
/// Each case carries the suffix portion of a canonical conformance URI under
/// `https://api.stacspec.org/v1.0.*`. Use ``validURI`` to obtain the canonical
/// URI form that pystac-client emits (with the literal `*` patch wildcard, so
/// that `matches(_:)` self-recognises it), and ``matches(_:)`` to test whether
/// an arbitrary advertised URI satisfies this class.
public enum ConformanceClass: String, CaseIterable, Sendable {
    case CORE = "/core"
    case COLLECTIONS = "/collections"
    case FEATURES = "/ogcapi-features"
    case ITEM_SEARCH = "/item-search"

    case CONTEXT = "/item-search#context"
    case FIELDS = "/item-search#fields"
    case SORT = "/item-search#sort"
    case QUERY = "/item-search#query"
    case FILTER = "/item-search#filter"

    case COLLECTION_SEARCH = "/collection-search"
    case COLLECTION_SEARCH_FREE_TEXT = "/collection-search#free-text"

    /// The canonical URI string that pystac-client uses when *writing* a
    /// `conformsTo` entry. The literal `*` is intentional — ``matches(_:)``
    /// accepts any characters between `v1.0.` and the rawValue suffix, so
    /// this string is its own valid identifier.
    public var validURI: String { "https://api.stacspec.org/v1.0.*\(rawValue)" }

    /// True if the given advertised conformance URI matches this class.
    ///
    /// Mirrors the Python regex `^https://api\.stacspec\.org/v1\.0\.(.*)<suffix>$`.
    /// Anything between `v1.0.` and the suffix is accepted, so
    /// `https://api.stacspec.org/v1.0.0/item-search`,
    /// `https://api.stacspec.org/v1.0.0-rc.2/item-search`, and the literal
    /// `v1.0.*` form all match ``ITEM_SEARCH``.
    public func matches(_ uri: String) -> Bool {
        let prefix = "https://api.stacspec.org/v1.0."
        guard uri.hasPrefix(prefix), uri.hasSuffix(rawValue) else { return false }
        return uri.count >= prefix.count + rawValue.count
    }

    /// The case name as a string (e.g. `"CORE"`). Used in warnings.
    public var name: String {
        switch self {
        case .CORE: return "CORE"
        case .COLLECTIONS: return "COLLECTIONS"
        case .FEATURES: return "FEATURES"
        case .ITEM_SEARCH: return "ITEM_SEARCH"
        case .CONTEXT: return "CONTEXT"
        case .FIELDS: return "FIELDS"
        case .SORT: return "SORT"
        case .QUERY: return "QUERY"
        case .FILTER: return "FILTER"
        case .COLLECTION_SEARCH: return "COLLECTION_SEARCH"
        case .COLLECTION_SEARCH_FREE_TEXT: return "COLLECTION_SEARCH_FREE_TEXT"
        }
    }

    /// Look up a conformance class by case name (case-insensitive). Throws
    /// ``STACClientError/generic(_:)`` if the name is not recognised — the
    /// message mirrors pystac-client's `ValueError`.
    public static func byName(_ name: String) throws -> ConformanceClass {
        let needle = name.uppercased()
        if let m = ConformanceClass.allCases.first(where: { $0.name == needle }) {
            return m
        }
        throw STACClientError.generic("Invalid conformance class '\(name)'")
    }
}
