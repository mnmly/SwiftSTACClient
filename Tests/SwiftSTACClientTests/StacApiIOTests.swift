import XCTest
import SwiftSTAC
@testable import SwiftSTACClient

final class StacApiIOTests: XCTestCase {

    func test_readJSON_returnsDecodedObject() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/collections/foo",
                        json: #"{"id":"foo","type":"Collection"}"#)
        let io = StacApiIO(transport: mock)
        let json = try await io.readJSON("https://api.example.com/collections/foo")
        XCTAssertEqual(json["id"]?.stringValue, "foo")
        XCTAssertEqual(json["type"]?.stringValue, "Collection")
    }

    func test_request_throwsAPIErrorWithStatusOnNon200() async throws {
        let mock = MockHTTPTransport()
        await mock.stub404(.GET, "https://api.example.com/collections/missing")
        let io = StacApiIO(transport: mock)
        do {
            _ = try await io.readJSON("https://api.example.com/collections/missing")
            XCTFail("expected throw")
        } catch let err as STACClientError {
            XCTAssertEqual(err.statusCode, 404)
        }
    }

    func test_sessionHeadersAreSent() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/", json: #"{"ok":true}"#)
        let io = StacApiIO(transport: mock, headers: ["Authorization": "Bearer abc"])
        _ = try await io.readJSON("https://api.example.com/")
        let sent = await mock.sentRequests
        XCTAssertEqual(sent.first?.headers["Authorization"], "Bearer abc")
    }

    func test_sessionParametersAppendedToGETQuery() async throws {
        let mock = MockHTTPTransport()
        // Use a bare stub (query-stripped) so it matches regardless of params.
        await mock.stub(.GET, "https://api.example.com/search", json: #"{"features":[]}"#)
        let io = StacApiIO(transport: mock, parameters: ["api_key": "xyz"])
        _ = try await io.readJSON("https://api.example.com/search")
        let sent = await mock.sentRequests
        XCTAssertTrue(sent.first!.url.contains("api_key=xyz"),
                      "URL should carry session parameter; got \(sent.first!.url)")
    }

    func test_postBodyContainsJSONParameters() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.POST, "https://api.example.com/search", json: #"{"features":[]}"#)
        let io = StacApiIO(transport: mock)
        _ = try await io.readJSON(
            "https://api.example.com/search",
            method: .POST,
            parameters: ["limit": .int(5), "collections": .array([.string("s2")])]
        )
        let sent = await mock.sentRequests
        let body = sent.first?.body ?? Data()
        let decoded = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(decoded["limit"], .int(5))
        XCTAssertEqual(decoded["collections"]?.arrayValue?.first?.stringValue, "s2")
        XCTAssertEqual(sent.first?.headers["Content-Type"], "application/json")
    }

    func test_pages_walksNextLinksUntilEmpty() async throws {
        let mock = MockHTTPTransport()
        // Page 1: has items + a "next" link
        await mock.stub(.GET, "https://api.example.com/search", json: """
        {"features":[{"id":"a","type":"Feature"}],"links":[
            {"rel":"next","href":"https://api.example.com/search/p2","method":"GET"}
        ]}
        """)
        // Page 2: more items, no next
        await mock.stub(.GET, "https://api.example.com/search/p2", json: """
        {"features":[{"id":"b","type":"Feature"}],"links":[]}
        """)
        let io = StacApiIO(transport: mock)
        var ids: [String] = []
        for try await page in io.pages("https://api.example.com/search") {
            for f in page["features"]?.arrayValue ?? [] {
                if let id = f["id"]?.stringValue { ids.append(id) }
            }
        }
        XCTAssertEqual(ids, ["a", "b"])
    }

    func test_pages_stopsWhenPageHasNoFeatures() async throws {
        let mock = MockHTTPTransport()
        await mock.stub(.GET, "https://api.example.com/search",
                        json: #"{"features":[],"links":[]}"#)
        let io = StacApiIO(transport: mock)
        var count = 0
        for try await _ in io.pages("https://api.example.com/search") { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func test_pages_followsPOSTNextWithMergedBody() async throws {
        let mock = MockHTTPTransport()
        // Page 1: POST /search → one feature + a POST next with merge=true.
        await mock.stubExact(.POST, "https://api.example.com/search", json: """
        {"features":[{"id":"a","type":"Feature"}],"links":[
            {"rel":"next","href":"https://api.example.com/search/p2","method":"POST",
             "merge":true,"body":{"token":"abc"}}
        ]}
        """)
        // Page 2: terminal, no next.
        await mock.stub(.POST, "https://api.example.com/search/p2", json: """
        {"features":[{"id":"b","type":"Feature"}],"links":[]}
        """)
        let io = StacApiIO(transport: mock)
        var pages: [[String: JSONValue]] = []
        for try await page in io.pages("https://api.example.com/search",
                                       method: .POST,
                                       parameters: ["limit": .int(1)]) {
            pages.append(page)
        }
        XCTAssertEqual(pages.count, 2)
        let sent = await mock.sentRequests
        XCTAssertEqual(sent.count, 2)
        let body2 = try JSONDecoder().decode(JSONValue.self, from: sent[1].body ?? Data())
        XCTAssertEqual(body2["token"]?.stringValue, "abc")
        XCTAssertEqual(body2["limit"]?.intValue, 1)
    }
}
