import Foundation
import SwiftSTAC

/// A `SwiftSTAC.Collection` augmented with API-aware item iteration.
/// Mirrors `pystac_client.collection_client.CollectionClient`.
///
/// A `CollectionClient` carries a back-reference to its parent ``Client`` so
/// it can route ``CollectionClient/items(ids:)`` and ``getItem(_:)`` to the API's `/search`,
/// `/collections/{id}/items`, or `/collections/{id}/items/{id}` endpoints as
/// appropriate.
public final class CollectionClient {

    /// The underlying domain object.
    public let collection: Collection

    /// Back-reference to the API client that produced this collection.
    public unowned let client: Client

    public init(collection: Collection, client: Client) {
        self.collection = collection
        self.client = client
    }

    /// Construct from a parsed JSON dict.
    public static func fromDict(_ d: [String: JSONValue], client: Client) throws -> CollectionClient {
        let c = try Collection.parse(d)
        return CollectionClient(collection: c, client: client)
    }

    /// Wrap an already-built `SwiftSTAC.Collection`.
    public static func fromCollection(_ c: Collection, client: Client) throws -> CollectionClient {
        CollectionClient(collection: c, client: client)
    }

    public var id: String { collection.id }

    // MARK: - Item access

    private func itemsHref() -> String {
        if let link = collection.getSingleLink(rel: "items"),
           let h = link.getAbsoluteHref() {
            return h
        }
        return joinPath(collection.getSelfHref() ?? "", "items")
    }

    /// Async stream of every item in this collection, optionally filtered
    /// by id. Uses the API's `/search` endpoint when available, otherwise
    /// the collection's `/items` endpoint.
    public func items(ids: [String]? = nil) -> AsyncThrowingStream<Item, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url: String
                    if self.client.conformsTo(.ITEM_SEARCH) {
                        url = self.client.searchHref()
                    } else {
                        url = self.itemsHref()
                    }
                    let params = try SearchParameters(method: .GET, ids: ids, collections: [self.id])
                    let search = ItemSearch(url: url, parameters: params, io: self.client.io, modifier: self.client.modifier)
                    for try await item in search.items() {
                        continuation.yield(item)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fetch a single item by id. Uses `/collections/{id}/items/{id}` if the
    /// API supports `FEATURES`; otherwise routes through `/search`.
    public func getItem(_ id: String) async throws -> Item? {
        if client.conformsTo(.FEATURES) {
            let url = joinPath(itemsHref(), id)
            do {
                let dict = try await client.io.readJSON(url)
                let item = try Item.fromDict(dict)
                client.modifier?(.item(item))
                return item
            } catch let err as STACClientError {
                if err.statusCode == 404 { return nil }
                throw err
            }
        }
        if client.conformsTo(.ITEM_SEARCH) {
            let params = try SearchParameters(method: .GET, ids: [id], collections: [self.id])
            let search = ItemSearch(url: client.searchHref(), parameters: params, io: client.io, modifier: client.modifier)
            var it = search.items().makeAsyncIterator()
            return try await it.next()
        }
        try? await STACWarnings.emit(.fallbackToPystac)
        return nil
    }
}
