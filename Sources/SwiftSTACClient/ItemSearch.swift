import Foundation
import SwiftSTAC

// MARK: - Parameter helpers

/// Either-or container for filter expressions: `dict` (CQL2-JSON) or `text`
/// (CQL2-Text).
public enum FilterExpression: Sendable, Hashable {
    case dict([String: JSONValue])
    case text(String)
}

/// Sort direction.
public enum SortDirection: String, Sendable, Hashable {
    case asc
    case desc
}

/// One sort component. Mirrors the dict entries pystac-client emits, e.g.
/// `{"field": "datetime", "direction": "desc"}`.
public struct SortSpec: Sendable, Hashable {
    public var field: String
    public var direction: SortDirection
    public init(field: String, direction: SortDirection = .asc) {
        self.field = field
        self.direction = direction
    }

    /// Parse a single shorthand sort token: `-foo` (desc), `+foo`/`foo` (asc).
    public static func parse(_ part: String) -> SortSpec {
        if part.hasPrefix("-") { return .init(field: String(part.dropFirst()), direction: .desc) }
        if part.hasPrefix("+") { return .init(field: String(part.dropFirst()), direction: .asc) }
        return .init(field: part, direction: .asc)
    }
}

/// Fields selector for the `fields` STAC API extension.
public struct FieldsSelector: Sendable, Hashable {
    public var include: [String]
    public var exclude: [String]

    public init(include: [String] = [], exclude: [String] = []) {
        self.include = include
        self.exclude = exclude
    }

    /// Parse a list of `+field` / `-field` / `field` tokens into include/exclude.
    public static func parse(_ parts: [String]) -> FieldsSelector {
        var inc: [String] = []
        var exc: [String] = []
        for f in parts {
            if f.hasPrefix("-") { exc.append(String(f.dropFirst())) }
            else if f.hasPrefix("+") { inc.append(String(f.dropFirst())) }
            else { inc.append(f) }
        }
        return .init(include: inc, exclude: exc)
    }
}

// MARK: - Base search parameter builder

/// Builds the query-parameter dictionary used by both ``ItemSearch`` and
/// ``CollectionSearch``. Mirrors `pystac_client.item_search.BaseSearch`.
///
/// This is a `struct` (no mutable shared state) so it's trivially Sendable
/// and can be freely copied across actors. Build it once with the desired
/// filters, then iterate results through ``ItemSearch/items()`` / ``ItemSearch/pages()``.
public struct SearchParameters: Sendable {
    public var method: HTTPMethod
    public var maxItems: Int?
    public var limit: Int?
    public var ids: [String]?
    public var collections: [String]?
    public var bbox: [Double]?
    public var intersects: [String: JSONValue]?
    public var datetime: String?
    public var query: [String: JSONValue]?
    public var filter: FilterExpression?
    public var filterLang: String?
    public var sortby: [SortSpec]?
    public var fields: FieldsSelector?
    public var freeText: String?

    public init(
        method: HTTPMethod = .POST,
        maxItems: Int? = nil,
        limit: Int? = nil,
        ids: [String]? = nil,
        collections: [String]? = nil,
        bbox: [Double]? = nil,
        intersects: [String: JSONValue]? = nil,
        datetime: String? = nil,
        query: [String: JSONValue]? = nil,
        filter: FilterExpression? = nil,
        filterLang: String? = nil,
        sortby: [SortSpec]? = nil,
        fields: FieldsSelector? = nil,
        freeText: String? = nil
    ) throws {
        if let limit, limit < 1 || limit > 10_000 {
            throw STACClientError.parameters("Invalid limit \(limit), must be between 1 and 10,000")
        }
        self.method = method
        self.maxItems = maxItems
        self.limit = (maxItems != nil && limit != nil) ? min(limit!, maxItems!) : limit
        self.ids = ids
        self.collections = collections
        self.bbox = bbox
        self.intersects = intersects
        self.datetime = SearchParameters.normalizeDatetime(datetime)
        self.query = query
        self.filter = filter
        self.filterLang = SearchParameters.resolvedFilterLang(method: method, filter: filter, given: filterLang)
        self.sortby = sortby
        self.fields = fields
        self.freeText = freeText
    }

    /// The body dict used for `POST`, or the input dict to `queryString()` for GET.
    public func asPOSTBody() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let limit { out["limit"] = .int(Int64(limit)) }
        if let bbox { out["bbox"] = .array(bbox.map { .double($0) }) }
        if let datetime { out["datetime"] = .string(datetime) }
        if let ids { out["ids"] = .array(ids.map { .string($0) }) }
        if let collections { out["collections"] = .array(collections.map { .string($0) }) }
        if let intersects { out["intersects"] = .object(intersects) }
        if let query { out["query"] = .object(query) }
        if let filter {
            switch filter {
            case .dict(let d): out["filter"] = .object(d)
            case .text(let s): out["filter"] = .string(s)
            }
        }
        if let filterLang { out["filter-lang"] = .string(filterLang) }
        if let sortby { out["sortby"] = .array(sortby.map { .object([
            "field": .string($0.field),
            "direction": .string($0.direction.rawValue)
        ]) }) }
        if let fields {
            out["fields"] = .object([
                "include": .array(fields.include.map { .string($0) }),
                "exclude": .array(fields.exclude.map { .string($0) })
            ])
        }
        if let freeText { out["q"] = .string(freeText) }
        return out
    }

    /// Render this parameter set as a GET query-string dictionary (values
    /// already serialized).
    public func asGETQuery() -> [String: String] {
        var q: [String: String] = [:]
        if let limit { q["limit"] = String(limit) }
        if let bbox { q["bbox"] = bbox.map { String($0) }.joined(separator: ",") }
        if let datetime { q["datetime"] = datetime }
        if let ids { q["ids"] = ids.joined(separator: ",") }
        if let collections { q["collections"] = collections.joined(separator: ",") }
        if let intersects, let s = jsonCompact(.object(intersects)) { q["intersects"] = s }
        if let query, let s = jsonCompact(.object(query)) { q["query"] = s }
        if let filter {
            switch filter {
            case .text(let s): q["filter"] = s
            case .dict(let d): if let s = jsonCompact(.object(d)) { q["filter"] = s }
            }
        }
        if let filterLang { q["filter-lang"] = filterLang }
        if let sortby {
            q["sortby"] = sortby.map { "\($0.direction == .asc ? "+" : "-")\($0.field)" }.joined(separator: ",")
        }
        if let fields {
            let inc = fields.include.map { "+\($0)" }
            let exc = fields.exclude.map { "-\($0)" }
            q["fields"] = (inc + exc).joined(separator: ",")
        }
        if let freeText { q["q"] = freeText }
        return q
    }

    // MARK: - Helpers

    private static func resolvedFilterLang(
        method: HTTPMethod,
        filter: FilterExpression?,
        given: String?
    ) -> String? {
        guard filter != nil else { return nil }
        if let given { return given }
        switch method {
        case .GET: return "cql2-text"
        case .POST: return "cql2-json"
        }
    }

    /// Mirrors `_to_isoformat_range` + `_format_datetime`: keep already-formed
    /// strings as-is, expand bare `YYYY` / `YYYY-MM` / `YYYY-MM-DD` / `/`-joined
    /// pairs into RFC 3339 spans with a `Z`.
    static func normalizeDatetime(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        // If it already contains a `/` we trust the caller's structure but
        // still normalize each side.
        if value.contains("/") {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return value }
            let (s1, _) = expandComponent(parts[0])
            let (s2, e2) = expandComponent(parts[1])
            return "\(s1)/\(e2 ?? s2)"
        }
        let (s, e) = expandComponent(value)
        if let e { return "\(s)/\(e)" }
        return s
    }

    /// Expand a single datetime component. Returns `(start, optional end)` —
    /// `end` is set only when the input was a partial date (year/month/day).
    static func expandComponent(_ c: String) -> (String, String?) {
        if c == ".." || c.isEmpty { return ("..", nil) }
        // If looks like a fully-formed timestamp, keep as-is (add Z if no tz).
        if c.contains("T") || c.contains("t") {
            let lower = c.lowercased()
            let hasTZ = lower.hasSuffix("z") || hasOffset(lower)
            return (hasTZ ? c : c + "Z", nil)
        }
        let parts = c.split(separator: "-").map(String.init)
        if parts.count == 1, let year = Int(parts[0]) {
            return ("\(year)-01-01T00:00:00Z", "\(year)-12-31T23:59:59Z")
        }
        if parts.count == 2,
           let year = Int(parts[0]), let month = Int(parts[1]) {
            let mm = String(format: "%02d", month)
            let lastDay = daysIn(year: year, month: month)
            return ("\(year)-\(mm)-01T00:00:00Z", "\(year)-\(mm)-\(String(format: "%02d", lastDay))T23:59:59Z")
        }
        if parts.count == 3,
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
            let mm = String(format: "%02d", month)
            let dd = String(format: "%02d", day)
            return ("\(year)-\(mm)-\(dd)T00:00:00Z", "\(year)-\(mm)-\(dd)T23:59:59Z")
        }
        return (c, nil)
    }

    private static func hasOffset(_ s: String) -> Bool {
        // After the T there might be `+HH:MM` or `-HH:MM`. Skip the leading
        // date `YYYY-MM-DD` dashes.
        guard let tIdx = s.firstIndex(where: { $0 == "t" }) else { return false }
        let after = s[s.index(after: tIdx)...]
        return after.contains("+") || after.contains("-")
    }

    private static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        default: return 30
        }
    }
}

private func jsonCompact(_ v: JSONValue) -> String? {
    let enc = JSONEncoder()
    enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    guard let data = try? enc.encode(v), let s = String(data: data, encoding: .utf8) else { return nil }
    return s
}

// MARK: - ItemSearch

/// A deferred query against a STAC API `/search` endpoint. Mirrors
/// `pystac_client.item_search.ItemSearch`.
///
/// `ItemSearch` holds the search parameters and a reference to the
/// ``StacApiIO`` actor. No request is sent until the caller iterates over
/// ``CollectionClient/items(ids:)``, ``pages()``, or calls ``matched()``.
///
/// `ItemSearch` is not `Sendable` when a ``modifier`` is set, because
/// SwiftSTAC's `SwiftSTAC.Item` / `SwiftSTAC.ItemCollection` are not
/// `Sendable` and the modifier receives them by reference. Own it within a
/// single task hierarchy; the underlying ``io`` actor is still safe to share.
public struct ItemSearch {
    public let url: String
    public let parameters: SearchParameters
    public let io: StacApiIO

    /// Per-result mutator invoked on every Item yielded by ``CollectionClient/items(ids:)`` and
    /// on every page dict yielded by ``ItemSearch/pages()``. Mirrors pystac-client's
    /// `modifier` parameter.
    public let modifier: ((Client.Modifiable) -> Void)?

    public init(
        url: String,
        parameters: SearchParameters,
        io: StacApiIO,
        modifier: ((Client.Modifiable) -> Void)? = nil
    ) {
        self.url = url
        self.parameters = parameters
        self.io = io
        self.modifier = modifier
    }

    /// Build the URL pystac-client would use for an equivalent GET request.
    /// Useful for logging and debugging.
    public func urlWithParameters() -> String {
        let q = parameters.asGETQuery()
        guard !q.isEmpty else { return url }
        var comps = URLComponents(string: url)
        comps?.queryItems = q.keys.sorted().map { URLQueryItem(name: $0, value: q[$0]) }
        return comps?.string ?? url
    }

    /// Async stream of result pages (full feature-collection dicts).
    ///
    /// If the caller chose `POST` but the server returns `405 Method Not
    /// Allowed`, the search transparently retries with `GET` for the rest of
    /// the iteration — mirrors pystac-client's auto-fallback behaviour.
    public func pages() -> AsyncThrowingStream<[String: JSONValue], Error> {
        let url = self.url
        let parameters = self.parameters
        let io = self.io
        let maxItems = parameters.maxItems
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var pageStream = io.pages(url, method: parameters.method, parameters: parameters.asPOSTBody())
                    var iterator = pageStream.makeAsyncIterator()
                    var emitted = 0
                    while true {
                        let page: [String: JSONValue]?
                        do {
                            page = try await iterator.next()
                        } catch let err as STACClientError where err.statusCode == 405 && parameters.method == .POST {
                            // Retry as GET and continue iterating from the first page.
                            var fallbackParams = parameters
                            fallbackParams.method = .GET
                            pageStream = io.pages(url, method: .GET, parameters: fallbackParams.asPOSTBody())
                            iterator = pageStream.makeAsyncIterator()
                            continue
                        }
                        guard let page else { break }
                        var p = page
                        var features = page["features"]?.arrayValue ?? []
                        if let maxItems {
                            let remaining = maxItems - emitted
                            if remaining <= 0 { break }
                            if features.count > remaining {
                                features = Array(features.prefix(remaining))
                                p["features"] = .array(features)
                            }
                        }
                        emitted += features.count
                        continuation.yield(p)
                        if let maxItems, emitted >= maxItems { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Async stream of every matched item. If a ``modifier`` was set on this
    /// search, it is invoked on every emitted `SwiftSTAC.Item` before the
    /// consumer sees it.
    public func items() -> AsyncThrowingStream<Item, Error> {
        let pages = self.pages()
        let modifier = self.modifier
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await page in pages {
                        for feature in page["features"]?.arrayValue ?? [] {
                            guard case let .object(o) = feature else { continue }
                            let item = try Item.fromDict(o)
                            modifier?(.item(item))
                            continuation.yield(item)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Collect all matched items into an array. Convenience for callers who
    /// don't need streaming.
    public func collect() async throws -> [Item] {
        var out: [Item] = []
        for try await item in items() { out.append(item) }
        return out
    }

    /// As an `ItemCollection`. Mirrors `item_collection` in pystac-client.
    /// The ``modifier`` (if any) fires on each underlying Item during
    /// ``collect()`` and once more on the assembled collection.
    public func itemCollection() async throws -> ItemCollection {
        let coll = ItemCollection(items: try await collect())
        modifier?(.itemCollection(coll))
        return coll
    }

    /// Number of matched results, if the server reports it via
    /// `numberMatched` or `context.matched`. Returns `nil` if the server
    /// doesn't advertise a total.
    public func matched() async throws -> Int? {
        var probeParams = parameters.asPOSTBody()
        probeParams["limit"] = .int(1)
        let resp = try await io.readJSON(url, method: parameters.method, parameters: probeParams)
        if let ctx = resp["context"]?.objectValue, let m = ctx["matched"]?.intValue {
            return Int(m)
        }
        if let n = resp["numberMatched"]?.intValue {
            return Int(n)
        }
        return nil
    }
}
