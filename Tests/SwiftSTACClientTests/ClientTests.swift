import XCTest
import SwiftSTAC
@testable import SwiftSTACClient

final class ClientTests: XCTestCase {

    // MARK: - Helpers

    /// Landing-page JSON for a STAC API root.
    private func landingPage(conformance: [String] = [], extraLinks: [String] = []) -> String {
        let conf = conformance.map { "\"\($0)\"" }.joined(separator: ",")
        let links = extraLinks.joined(separator: ",")
        return """
        {
          "type": "Catalog",
          "stac_version": "1.0.0",
          "id": "test-catalog",
          "description": "test",
          "conformsTo": [\(conf)],
          "links": [
            {"rel":"self","href":"https://api.example.com/"},
            {"rel":"root","href":"https://api.example.com/"}
            \(links.isEmpty ? "" : "," + links)
          ]
        }
        """
    }

    // MARK: - open / conformance

    func test_open_returnsClientForCatalogTypeDocument() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/", json: landingPage())
        let client = try await Client.open(url: "https://api.example.com/", transport: mock)
        XCTAssertEqual(client.id, "test-catalog")
    }

    func test_open_throwsClientTypeForItem() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/",
                        json: #"{"type":"Feature","stac_version":"1.0.0","id":"i","properties":{"datetime":"2024-01-01T00:00:00Z"},"geometry":null,"links":[],"assets":{}}"#)
        do {
            _ = try await Client.open(url: "https://api.example.com/", transport: mock)
            XCTFail("expected throw")
        } catch let err as STACClientError {
            if case .clientType = err {} else { XCTFail("wrong case: \(err)") }
        }
    }

    func test_conformsTo_matchesAdvertisedURI() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/",
                        json: landingPage(conformance: ["https://api.stacspec.org/v1.0.0/item-search"]))
        let client = try await Client.open(url: "https://api.example.com/", transport: mock)
        XCTAssertTrue(client.conformsTo(.ITEM_SEARCH))
        XCTAssertFalse(client.conformsTo(.COLLECTIONS))
    }

    func test_addAndRemoveConformsTo_byName() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/", json: landingPage(conformance: []))
        let client = try await Client.open(url: "https://api.example.com/", transport: mock)
        try client.addConformsTo("FILTER")
        XCTAssertTrue(client.conformsTo(.FILTER))
        try client.removeConformsTo("FILTER")
        XCTAssertFalse(client.conformsTo(.FILTER))
    }

    // MARK: - getCollection

    func test_getCollection_returnsNilOn404() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/",
                        json: landingPage(conformance: ["https://api.stacspec.org/v1.0.0/collections"]))
        await mock.stub404(.GET, "https://api.example.com/collections/missing")
        let client = try await Client.open(url: "https://api.example.com/", transport: mock)
        let c = try await client.getCollection("missing")
        XCTAssertNil(c)
    }

    func test_getCollection_returnsCollectionClient() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/",
                        json: landingPage(conformance: ["https://api.stacspec.org/v1.0.0/collections"]))
        await mock.stub(.GET, "https://api.example.com/collections/foo", json: """
        {"type":"Collection","stac_version":"1.0.0","id":"foo","description":"d","license":"proprietary",
         "extent":{"spatial":{"bbox":[[-180,-90,180,90]]},"temporal":{"interval":[[null,null]]}},
         "links":[]}
        """)
        let client = try await Client.open(url: "https://api.example.com/", transport: mock)
        let c = try await client.getCollection("foo")
        XCTAssertEqual(c?.id, "foo")
    }

    // MARK: - search

    func test_search_throwsWhenAPIDoesNotConform() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/", json: landingPage())
        let client = try await Client.open(url: "https://api.example.com/", transport: mock)
        XCTAssertThrowsError(try client.search()) { err in
            guard case STACClientError.doesNotConformTo(let name) = err else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(name, "ITEM_SEARCH")
        }
    }

    func test_search_buildsItemSearchPointingAtSearchHref() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/",
                        json: landingPage(
                            conformance: ["https://api.stacspec.org/v1.0.0/item-search"],
                            extraLinks: [#"{"rel":"search","href":"https://api.example.com/search","type":"application/geo+json"}"#]
                        ))
        let client = try await Client.open(url: "https://api.example.com/", transport: mock)
        let search = try client.search(limit: 5, collections: ["s2"])
        XCTAssertEqual(search.url, "https://api.example.com/search")
        XCTAssertEqual(search.parameters.limit, 5)
        XCTAssertEqual(search.parameters.collections, ["s2"])
    }

    func test_search_iteratesItemsAcrossPages() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/",
                        json: landingPage(
                            conformance: ["https://api.stacspec.org/v1.0.0/item-search"],
                            extraLinks: [#"{"rel":"search","href":"https://api.example.com/search","type":"application/geo+json"}"#]
                        ))
        // Two pages of items via POST search.
        await mock.stub(.POST, "https://api.example.com/search", json: """
        {"type":"FeatureCollection","features":[
            {"type":"Feature","stac_version":"1.0.0","id":"a","collection":"c","properties":{"datetime":"2024-01-01T00:00:00Z"},"geometry":null,"links":[],"assets":{}}
        ],"links":[{"rel":"next","href":"https://api.example.com/search/p2","method":"GET"}]}
        """)
        await mock.stub(.GET, "https://api.example.com/search/p2", json: """
        {"type":"FeatureCollection","features":[
            {"type":"Feature","stac_version":"1.0.0","id":"b","collection":"c","properties":{"datetime":"2024-01-02T00:00:00Z"},"geometry":null,"links":[],"assets":{}}
        ],"links":[]}
        """)
        let client = try await Client.open(url: "https://api.example.com/", transport: mock)
        let search = try client.search()
        let items = try await search.collect()
        XCTAssertEqual(items.map(\.id), ["a", "b"])
    }

    // MARK: - collections

    func test_getSearchLink_returnsLandingLink() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/",
                        json: landingPage(
                            conformance: ["https://api.stacspec.org/v1.0.0/item-search"],
                            extraLinks: [#"{"rel":"search","href":"https://api.example.com/search","type":"application/geo+json"}"#]
                        ))
        let client = try await Client.open(url: "https://api.example.com/", transport: mock)
        XCTAssertEqual(client.getSearchLink()?.getHref(), "https://api.example.com/search")
        XCTAssertEqual(client.searchHref(), "https://api.example.com/search")
    }

    func test_getItems_throwsWithoutItemSearch() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/", json: landingPage())
        let client = try await Client.open(url: "https://api.example.com/", transport: mock)
        XCTAssertThrowsError(try client.getItems(ids: ["a"])) { err in
            guard case STACClientError.doesNotConformTo = err else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    func test_getItems_buildsSearchWithIds() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/",
                        json: landingPage(
                            conformance: ["https://api.stacspec.org/v1.0.0/item-search"],
                            extraLinks: [#"{"rel":"search","href":"https://api.example.com/search","type":"application/geo+json"}"#]
                        ))
        let client = try await Client.open(url: "https://api.example.com/", transport: mock)
        let s = try client.getItems(ids: ["foo", "bar"])
        XCTAssertEqual(s.parameters.ids, ["foo", "bar"])
    }

    func test_modifier_appliedOnGetCollection() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/",
                        json: landingPage(conformance: ["https://api.stacspec.org/v1.0.0/collections"]))
        await mock.stub(.GET, "https://api.example.com/collections/foo", json: """
        {"type":"Collection","stac_version":"1.0.0","id":"foo","description":"d","license":"proprietary",
         "extent":{"spatial":{"bbox":[[-180,-90,180,90]]},"temporal":{"interval":[[null,null]]}},
         "links":[]}
        """)
        final class Box { var ids: [String] = [] }
        let box = Box()
        let client = try await Client.open(url: "https://api.example.com/", transport: mock) { m in
            if case let .collection(c) = m { box.ids.append(c.id) }
        }
        _ = try await client.getCollection("foo")
        XCTAssertEqual(box.ids, ["foo"])
    }

    func test_collections_pagesAndReturnsAll() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/",
                        json: landingPage(conformance: ["https://api.stacspec.org/v1.0.0/collections"]))
        await mock.stub(.GET, "https://api.example.com/collections", json: """
        {"collections":[
            {"type":"Collection","stac_version":"1.0.0","id":"a","description":"","license":"l",
             "extent":{"spatial":{"bbox":[[-180,-90,180,90]]},"temporal":{"interval":[[null,null]]}},"links":[]},
            {"type":"Collection","stac_version":"1.0.0","id":"b","description":"","license":"l",
             "extent":{"spatial":{"bbox":[[-180,-90,180,90]]},"temporal":{"interval":[[null,null]]}},"links":[]}
        ],"links":[]}
        """)
        let client = try await Client.open(url: "https://api.example.com/", transport: mock)
        let cs = try await client.collections()
        XCTAssertEqual(cs.map(\.id), ["a", "b"])
    }
}
