import Foundation
import SwiftSTAC

/// Entry point for a STAC API. Mirrors `pystac_client.client.Client`.
///
/// A `Client` represents the root Catalog of a STAC API, plus the conformance
/// claims advertised in its landing page. Construct one with `open(url:io:modifier:)`
/// — the call reads the landing page and returns a ready-to-use client.
///
/// `Client` is a `final class` subclassing `SwiftSTAC.Catalog` so it slots
/// into the existing domain model. Like its superclass, `Client` is **not**
/// `Sendable` — own it within a single task hierarchy. The ``io`` actor it
/// holds is safe to share across tasks, and the ``ItemSearch`` /
/// ``CollectionSearch`` values it returns are Sendable.
public final class Client: Catalog {

    /// The IO actor that issues every request. Owned by the client and
    /// re-used by `ItemSearch` / `CollectionSearch` it returns.
    public let io: StacApiIO

    /// Modifier callback applied to every Collection / Item the client
    /// returns. Mirrors pystac-client's `modifier` parameter. The callback is
    /// invoked synchronously on the caller's task; SwiftSTAC's domain types
    /// are not `Sendable`, so the callback is not `@Sendable` either.
    public let modifier: ((Modifiable) -> Void)?

    /// Tagged-union over the per-result types the modifier sees. Not
    /// Sendable — mirrors the non-Sendable nature of SwiftSTAC's domain
    /// classes.
    public enum Modifiable {
        case item(Item)
        case collection(Collection)
        case itemCollection(ItemCollection)
    }

    private init(
        catalog: Catalog,
        io: StacApiIO,
        modifier: ((Modifiable) -> Void)?
    ) {
        self.io = io
        self.modifier = modifier
        super.init(
            id: catalog.id,
            description: catalog.description,
            title: catalog.title,
            stacExtensions: catalog.stacExtensions,
            extraFields: catalog.extraFields,
            href: nil,
            catalogType: catalog.catalogType
        )
        // Copy over the landing-page links; `links` is `public var` on STACObject.
        self.links = catalog.links
        if let href = catalog.getSelfHref() { setSelfHref(href) }
    }

    public required init(
        id: String,
        description: String,
        title: String? = nil,
        stacExtensions: [String] = [],
        extraFields: [String: JSONValue] = [:],
        href: String? = nil,
        catalogType: CatalogType = .absolutePublished
    ) {
        // Should never be invoked directly — use `open(url:io:modifier:)`.
        self.io = StacApiIO()
        self.modifier = nil
        super.init(
            id: id,
            description: description,
            title: title,
            stacExtensions: stacExtensions,
            extraFields: extraFields,
            href: href,
            catalogType: catalogType
        )
    }

    // MARK: - Opening

    /// Open a STAC API by reading its landing page.
    ///
    /// - Parameter url: The API root URL.
    /// - Parameter transport: HTTP transport. Defaults to a real `URLSession`.
    /// - Parameter headers: Headers merged into every request.
    /// - Parameter parameters: Query parameters merged into every GET.
    /// - Parameter modifier: Optional per-result mutator hook.
    public static func open(
        url: String,
        transport: HTTPTransport = URLSessionTransport(),
        headers: [String: String] = [:],
        parameters: [String: String] = [:],
        modifier: ((Modifiable) -> Void)? = nil
    ) async throws -> Client {
        let io = StacApiIO(transport: transport, headers: headers, parameters: parameters)
        return try await open(url: url, io: io, modifier: modifier)
    }

    /// Open a STAC API using a pre-built ``StacApiIO`` actor. Useful when you
    /// want to share one IO across multiple clients.
    public static func open(
        url: String,
        io: StacApiIO,
        modifier: ((Modifiable) -> Void)? = nil
    ) async throws -> Client {
        let dict = try await io.readJSON(url)
        let typ = dict["type"]?.stringValue
        guard typ == STACObjectType.catalog.rawValue || typ == STACObjectType.collection.rawValue else {
            throw STACClientError.clientType(
                "Could not open Client (href=\(url)), expected type=Catalog, found type=\(typ ?? "<missing>")"
            )
        }
        let cat = try Catalog.fromDict(dict)
        cat.setSelfHref(url)
        let client = Client(catalog: cat, io: io, modifier: modifier)
        if !client.hasConformsTo() {
            try? await STACWarnings.emit(.noConformsTo)
        }
        return client
    }

    // MARK: - conformsTo

    /// True if the landing page advertised a `conformsTo` list.
    public func hasConformsTo() -> Bool { extraFields["conformsTo"] != nil }

    /// The advertised conformance URIs (or empty if not advertised).
    public func getConformsTo() -> [String] {
        extraFields["conformsTo"]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    /// Replace the advertised `conformsTo` list.
    public func setConformsTo(_ uris: [String]) {
        extraFields["conformsTo"] = .array(uris.map { .string($0) })
    }

    /// Drop the `conformsTo` entry entirely.
    public func clearConformsTo() { extraFields.removeValue(forKey: "conformsTo") }

    /// Add a conformance class by name. No-op if already present.
    public func addConformsTo(_ name: String) throws {
        let cc = try ConformanceClass.byName(name)
        if !conformsTo(cc) {
            setConformsTo(getConformsTo() + [cc.validURI])
        }
    }

    /// Remove every advertised URI that satisfies the named class.
    public func removeConformsTo(_ name: String) throws {
        let cc = try ConformanceClass.byName(name)
        setConformsTo(getConformsTo().filter { !cc.matches($0) })
    }

    /// Whether the server advertises this conformance class.
    public func conformsTo(_ cc: ConformanceClass) -> Bool {
        getConformsTo().contains(where: { cc.matches($0) })
    }

    /// String overload — looks the class up by name.
    public func conformsTo(name: String) throws -> Bool {
        try conformsTo(ConformanceClass.byName(name))
    }

    // MARK: - Collections

    private func supportsCollections() -> Bool {
        conformsTo(.COLLECTIONS) || conformsTo(.FEATURES)
    }

    private func collectionsHref(_ collectionID: String? = nil) -> String {
        let dataLink = getSingleLink(rel: "data")
        let href = dataLink?.getAbsoluteHref() ?? joinPath(getSelfHref() ?? "", "collections")
        if let collectionID { return joinPath(href, collectionID) }
        return href
    }

    /// The `rel="search"` link on the landing page, if any.
    /// Mirrors `pystac_client.client.Client.get_search_link`.
    public func getSearchLink() -> Link? {
        links.first(where: { $0.rel == "search" })
    }

    /// Resolved URL for the `/search` endpoint — either the absolute href of
    /// the `rel="search"` link, or a `<self>/search` fallback.
    public func searchHref() -> String {
        getSearchLink()?.getAbsoluteHref() ?? joinPath(getSelfHref() ?? "", "search")
    }

    /// Fetch a single Collection by id. Returns `nil` for 404 to match
    /// pystac-client's behavior.
    public func getCollection(_ id: String) async throws -> CollectionClient? {
        guard !id.isEmpty else { throw STACClientError.parameters("collection_id must not be empty") }
        if supportsCollections() {
            let url = collectionsHref(id)
            do {
                let dict = try await io.readJSON(url)
                let cc = try CollectionClient.fromDict(dict, client: self)
                wrap(.collection(cc.collection))
                return cc
            } catch let err as STACClientError {
                if err.statusCode == 404 { return nil }
                throw err
            }
        }
        // Fallback: walk this catalog's collection children.
        try? await STACWarnings.emit(.fallbackToPystac)
        for c in getCollections() where c.id == id {
            return try CollectionClient.fromCollection(c, client: self)
        }
        return nil
    }

    /// All Collections in this API, eagerly paged.
    ///
    /// pystac-client streams over pages lazily, but ``CollectionClient`` is
    /// not `Sendable` (its back-reference to ``Client`` is not), so a typed
    /// `AsyncSequence` of it cannot cross task boundaries safely. Callers
    /// that need streaming should use ``rawCollectionPages()`` and parse
    /// each page themselves on the same task that owns the client.
    public func collections() async throws -> [CollectionClient] {
        if supportsCollections() {
            var out: [CollectionClient] = []
            for try await page in io.pages(collectionsHref()) {
                for c in page["collections"]?.arrayValue ?? [] {
                    guard case let .object(o) = c else { continue }
                    let cc = try CollectionClient.fromDict(o, client: self)
                    wrap(.collection(cc.collection))
                    out.append(cc)
                }
            }
            return out
        }
        try? await STACWarnings.emit(.fallbackToPystac)
        return try getCollections().map { try CollectionClient.fromCollection($0, client: self) }
    }

    /// Async stream of raw `/collections` page dicts. Use when you need
    /// streaming or want to parse JSON yourself. Each page is a Sendable
    /// `[String: JSONValue]`.
    public func rawCollectionPages() -> AsyncThrowingStream<[String: JSONValue], Error> {
        io.pages(collectionsHref())
    }

    // MARK: - Search

    /// Build a deferred ``ItemSearch`` against this API's `/search` endpoint.
    public func search(
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
        fields: FieldsSelector? = nil
    ) throws -> ItemSearch {
        guard conformsTo(.ITEM_SEARCH) else {
            throw STACClientError.doesNotConformTo("ITEM_SEARCH")
        }
        let params = try SearchParameters(
            method: method, maxItems: maxItems, limit: limit, ids: ids,
            collections: collections, bbox: bbox, intersects: intersects,
            datetime: datetime, query: query, filter: filter, filterLang: filterLang,
            sortby: sortby, fields: fields
        )
        return ItemSearch(url: searchHref(), parameters: params, io: io, modifier: modifier)
    }

    /// Convenience: iterate over items in this catalog, optionally filtered
    /// by id. Routes through `/search` when ``ConformanceClass/ITEM_SEARCH``
    /// is advertised — emits a ``STACClientWarning/fallbackToPystac``
    /// otherwise (no in-memory walk is performed; use SwiftSTAC directly for
    /// non-API catalogs).
    public func getItems(ids: [String]? = nil, limit: Int? = nil) throws -> ItemSearch {
        guard conformsTo(.ITEM_SEARCH) else {
            throw STACClientError.doesNotConformTo("ITEM_SEARCH")
        }
        return try search(limit: limit, ids: ids)
    }

    /// Build a deferred ``CollectionSearch`` against this API's `/collections`
    /// endpoint. If the server advertises neither `COLLECTION_SEARCH` nor
    /// `COLLECTIONS` *and* any filter was supplied, this throws — mirrors
    /// pystac-client's check.
    public func collectionSearch(
        maxCollections: Int? = nil,
        limit: Int? = nil,
        bbox: [Double]? = nil,
        datetime: String? = nil,
        freeText: String? = nil,
        query: [String: JSONValue]? = nil,
        filter: FilterExpression? = nil,
        filterLang: String? = nil,
        sortby: [SortSpec]? = nil,
        fields: FieldsSelector? = nil
    ) throws -> CollectionSearch {
        let supports = conformsTo(.COLLECTION_SEARCH) || conformsTo(.COLLECTIONS)
        let hasAnyFilter = bbox != nil || datetime != nil || freeText != nil
            || query != nil || filter != nil || sortby != nil || fields != nil
        if !supports && hasAnyFilter {
            throw STACClientError.doesNotConformTo("COLLECTION_SEARCH or COLLECTIONS")
        }
        let params = try SearchParameters(
            method: .GET, maxItems: maxCollections, limit: limit,
            bbox: bbox, datetime: datetime,
            query: query, filter: filter, filterLang: filterLang,
            sortby: sortby, fields: fields, freeText: freeText
        )
        return CollectionSearch(
            url: collectionsHref(),
            parameters: params,
            io: io,
            collectionSearchExtensionEnabled: conformsTo(.COLLECTION_SEARCH),
            collectionSearchFreeTextEnabled: conformsTo(.COLLECTION_SEARCH_FREE_TEXT)
        )
    }

    // MARK: - Internal

    /// Invoke the user's modifier callback and return the (possibly mutated)
    /// value.
    @discardableResult
    func wrap(_ m: Modifiable) -> Modifiable {
        if let modifier { modifier(m) }
        return m
    }
}

// MARK: - URL join helper

func joinPath(_ base: String, _ tail: String) -> String {
    guard var comps = URLComponents(string: base) else {
        if base.hasSuffix("/") { return base + tail }
        return base + "/" + tail
    }
    var path = comps.path
    if !path.hasSuffix("/") { path += "/" }
    comps.path = path + tail
    return comps.string ?? (base + "/" + tail)
}
