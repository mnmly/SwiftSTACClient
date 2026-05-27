import XCTest
import SwiftSTAC
@testable import SwiftSTACClient

final class ItemSearchTests: XCTestCase {

    // MARK: - SearchParameters

    func test_initRejectsLimitOutOfRange() {
        XCTAssertThrowsError(try SearchParameters(limit: 0))
        XCTAssertThrowsError(try SearchParameters(limit: 10_001))
    }

    func test_initClampsLimitToMaxItems() throws {
        let p = try SearchParameters(maxItems: 5, limit: 20)
        XCTAssertEqual(p.limit, 5)
    }

    func test_datetime_expandsYearToFullRange() throws {
        let p = try SearchParameters(datetime: "2017")
        XCTAssertEqual(p.datetime, "2017-01-01T00:00:00Z/2017-12-31T23:59:59Z")
    }

    func test_datetime_expandsMonthToFullRange() throws {
        let p = try SearchParameters(datetime: "2017-06")
        XCTAssertEqual(p.datetime, "2017-06-01T00:00:00Z/2017-06-30T23:59:59Z")
    }

    func test_datetime_expandsDayToFullRange() throws {
        let p = try SearchParameters(datetime: "2017-06-10")
        XCTAssertEqual(p.datetime, "2017-06-10T00:00:00Z/2017-06-10T23:59:59Z")
    }

    func test_datetime_keepsFullTimestamp() throws {
        let p = try SearchParameters(datetime: "2017-06-10T12:00:00Z")
        XCTAssertEqual(p.datetime, "2017-06-10T12:00:00Z")
    }

    func test_datetime_yearRangeExpansion() throws {
        let p = try SearchParameters(datetime: "2017/2018")
        XCTAssertEqual(p.datetime, "2017-01-01T00:00:00Z/2018-12-31T23:59:59Z")
    }

    func test_datetime_appendZWhenMissingTimezone() throws {
        let p = try SearchParameters(datetime: "2017-06-10T12:00:00")
        XCTAssertEqual(p.datetime, "2017-06-10T12:00:00Z")
    }

    // MARK: - filter-lang inference

    func test_filterLang_defaultsToCQL2JSONForPOST() throws {
        let p = try SearchParameters(method: .POST, filter: .dict(["op": .string("=")]))
        XCTAssertEqual(p.filterLang, "cql2-json")
    }

    func test_filterLang_defaultsToCQL2TextForGET() throws {
        let p = try SearchParameters(method: .GET, filter: .text("eo:cloud_cover < 10"))
        XCTAssertEqual(p.filterLang, "cql2-text")
    }

    func test_filterLang_isNilWithoutFilter() throws {
        let p = try SearchParameters(method: .GET)
        XCTAssertNil(p.filterLang)
    }

    // MARK: - GET query rendering

    func test_asGETQuery_joinsBboxIDsCollections() throws {
        let p = try SearchParameters(
            method: .GET, ids: ["a", "b"],
            collections: ["s2", "l8"],
            bbox: [-10, -20, 10, 20]
        )
        let q = p.asGETQuery()
        XCTAssertEqual(q["bbox"], "-10.0,-20.0,10.0,20.0")
        XCTAssertEqual(q["ids"], "a,b")
        XCTAssertEqual(q["collections"], "s2,l8")
    }

    func test_asGETQuery_sortbyEmitsSignedShorthand() throws {
        let p = try SearchParameters(
            method: .GET,
            sortby: [.init(field: "datetime", direction: .desc), .init(field: "eo:cloud_cover", direction: .asc)]
        )
        XCTAssertEqual(p.asGETQuery()["sortby"], "-datetime,+eo:cloud_cover")
    }

    func test_asGETQuery_fieldsEmitsIncludeExclude() throws {
        let p = try SearchParameters(
            method: .GET,
            fields: .init(include: ["properties.datetime"], exclude: ["geometry"])
        )
        XCTAssertEqual(p.asGETQuery()["fields"], "+properties.datetime,-geometry")
    }

    // MARK: - URL with parameters

    func test_urlWithParameters_appendsQueryItemsSorted() throws {
        let p = try SearchParameters(method: .GET, limit: 100, collections: ["s2"])
        let mock = MockHTTPTransport()
        let io = StacApiIO(transport: mock)
        let search = ItemSearch(url: "https://api.example.com/search", parameters: p, io: io)
        let url = search.urlWithParameters()
        XCTAssertTrue(url.hasPrefix("https://api.example.com/search?"))
        XCTAssertTrue(url.contains("collections=s2"))
        XCTAssertTrue(url.contains("limit=100"))
    }

    // MARK: - matched()

    func test_matched_readsContextMatched() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.POST, "https://api.example.com/search",
                        json: #"{"context":{"matched":42},"features":[]}"#)
        let io = StacApiIO(transport: mock)
        let p = try SearchParameters()
        let s = ItemSearch(url: "https://api.example.com/search", parameters: p, io: io)
        let m = try await s.matched()
        XCTAssertEqual(m, 42)
    }

    func test_matched_readsNumberMatched() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.POST, "https://api.example.com/search",
                        json: #"{"numberMatched":7,"features":[]}"#)
        let io = StacApiIO(transport: mock)
        let p = try SearchParameters()
        let s = ItemSearch(url: "https://api.example.com/search", parameters: p, io: io)
        let m = try await s.matched()
        XCTAssertEqual(m, 7)
    }

    func test_matched_returnsNilWhenServerOmits() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.POST, "https://api.example.com/search",
                        json: #"{"features":[]}"#)
        let io = StacApiIO(transport: mock)
        let p = try SearchParameters()
        let s = ItemSearch(url: "https://api.example.com/search", parameters: p, io: io)
        let m = try await s.matched()
        XCTAssertNil(m)
    }

    // MARK: - maxItems truncation

    // MARK: - Modifier

    func test_modifier_firesOnEveryItem() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.POST, "https://api.example.com/search", json: """
        {"features":[
          {"type":"Feature","stac_version":"1.0.0","id":"a","properties":{"datetime":"2024-01-01T00:00:00Z"},"geometry":null,"links":[],"assets":{}},
          {"type":"Feature","stac_version":"1.0.0","id":"b","properties":{"datetime":"2024-01-01T00:00:00Z"},"geometry":null,"links":[],"assets":{}}
        ],"links":[]}
        """)
        let io = StacApiIO(transport: mock)
        let p = try SearchParameters()

        final class Counter { var seen: [String] = [] }
        let counter = Counter()
        let s = ItemSearch(url: "https://api.example.com/search", parameters: p, io: io) { mod in
            if case let .item(it) = mod { counter.seen.append(it.id) }
        }
        let items = try await s.collect()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(counter.seen, ["a", "b"])
    }

    // MARK: - POST 405 → GET fallback

    func test_post405_fallsBackToGET() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.POST, "https://api.example.com/search", status: 405, json: "method not allowed")
        await mock.stub(.GET, "https://api.example.com/search", json: """
        {"features":[
          {"type":"Feature","stac_version":"1.0.0","id":"a","properties":{"datetime":"2024-01-01T00:00:00Z"},"geometry":null,"links":[],"assets":{}}
        ],"links":[]}
        """)
        let io = StacApiIO(transport: mock)
        let p = try SearchParameters(method: .POST)
        let s = ItemSearch(url: "https://api.example.com/search", parameters: p, io: io)
        let items = try await s.collect()
        XCTAssertEqual(items.map(\.id), ["a"])
        let sent = await mock.sentRequests
        XCTAssertEqual(sent.map(\.method), [.POST, .GET])
    }

    func test_pages_truncatesToMaxItems() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.POST, "https://api.example.com/search", json: """
        {"features":[
          {"type":"Feature","stac_version":"1.0.0","id":"a","properties":{"datetime":"2024-01-01T00:00:00Z"},"geometry":null,"links":[],"assets":{}},
          {"type":"Feature","stac_version":"1.0.0","id":"b","properties":{"datetime":"2024-01-01T00:00:00Z"},"geometry":null,"links":[],"assets":{}},
          {"type":"Feature","stac_version":"1.0.0","id":"c","properties":{"datetime":"2024-01-01T00:00:00Z"},"geometry":null,"links":[],"assets":{}}
        ],"links":[]}
        """)
        let io = StacApiIO(transport: mock)
        let p = try SearchParameters(maxItems: 2)
        let s = ItemSearch(url: "https://api.example.com/search", parameters: p, io: io)
        let items = try await s.collect()
        XCTAssertEqual(items.count, 2)
    }
}
