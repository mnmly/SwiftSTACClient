import XCTest
@testable import SwiftSTACClient

/// Translator-only tests. The full ``sqlite_text_search`` is not ported
/// (requires SQLite FTS5) — see CLAUDE.md for the deferred-scope note.
final class FreeTextTests: XCTestCase {

    func test_simpleTerm_passesThrough() {
        XCTAssertEqual(FreeText.parseQueryForSqlite("sentinel"), "sentinel")
    }

    func test_commaBecomesOR() {
        XCTAssertEqual(FreeText.parseQueryForSqlite("climate,model"),
                       "climate OR model")
    }

    func test_plusInclusionStripped() {
        XCTAssertEqual(FreeText.parseQueryForSqlite("quick +brown"),
                       "quick brown")
    }

    func test_minusExclusion_becomesNOT() {
        XCTAssertEqual(FreeText.parseQueryForSqlite("quick -fox"),
                       "quick NOT fox")
    }

    func test_specialCharacterTokenIsQuoted() {
        // `-` after a non-leading char is "special character in middle" → quote whole token.
        XCTAssertEqual(FreeText.parseQueryForSqlite("sentinel@2"),
                       "\"sentinel@2\"")
    }

    func test_quotedPhrasePreserved() {
        XCTAssertEqual(FreeText.parseQueryForSqlite("\"climate model\""),
                       "\"climate model\"")
    }

    func test_quotedPhraseWithCommaStaysOneToken() {
        XCTAssertEqual(FreeText.parseQueryForSqlite("\"models, etc\""),
                       "\"models, etc\"")
    }

    func test_parenthesesAreStandaloneTokens() {
        XCTAssertEqual(FreeText.parseQueryForSqlite("(quick OR brown) AND fox"),
                       "( quick OR brown ) AND fox")
    }
}
