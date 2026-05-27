import XCTest
@testable import SwiftSTACClient

final class ConformanceTests: XCTestCase {

    func test_byName_raisesForInvalidNames() {
        for bad in ["invalid", "nonexistent", ""] {
            XCTAssertThrowsError(try ConformanceClass.byName(bad)) { err in
                XCTAssertTrue(
                    String(describing: err).contains("Invalid conformance class '\(bad)'"),
                    "Unexpected error message: \(err)"
                )
            }
        }
    }

    func test_byName_validAndCaseInsensitive() throws {
        XCTAssertEqual(try ConformanceClass.byName("core"), .CORE)
        XCTAssertEqual(try ConformanceClass.byName("CORE"), .CORE)
        XCTAssertEqual(try ConformanceClass.byName("Item_Search"), .ITEM_SEARCH)
    }

    func test_validURI_includesWildcard() {
        XCTAssertEqual(ConformanceClass.CORE.validURI,
                       "https://api.stacspec.org/v1.0.*/core")
    }

    func test_matches_acceptsConcreteVersion() {
        XCTAssertTrue(ConformanceClass.CORE.matches(
            "https://api.stacspec.org/v1.0.0/core"))
        XCTAssertTrue(ConformanceClass.ITEM_SEARCH.matches(
            "https://api.stacspec.org/v1.0.0-rc.2/item-search"))
        // Filter has a fragment after the path — the suffix check still works.
        XCTAssertTrue(ConformanceClass.FILTER.matches(
            "https://api.stacspec.org/v1.0.0/item-search#filter"))
    }

    func test_matches_rejectsUnrelated() {
        XCTAssertFalse(ConformanceClass.CORE.matches(
            "https://example.com/v1.0.0/core"))
        XCTAssertFalse(ConformanceClass.CORE.matches(
            "https://api.stacspec.org/v1.0.0/collections"))
    }

    func test_validURI_isSelfMatching() {
        // pystac-client adds `validURI` to the conformsTo list — `matches` must accept it.
        for c in ConformanceClass.allCases {
            XCTAssertTrue(c.matches(c.validURI),
                          "validURI for \(c.name) is not self-matching")
        }
    }
}
