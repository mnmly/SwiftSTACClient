import Foundation

/// Free-text search helpers, mirroring `pystac_client.free_text`.
///
/// Only the query *translator* (``parseQueryForSqlite(_:)``) is ported: it
/// rewrites an OGC API Features Part 9 free-text query into the SQLite FTS5
/// syntax. The full `sqlite_text_search` helper that pystac-client uses for
/// client-side fallback filtering depends on SQLite FTS5 and is out of scope
/// for the initial Swift port — see the package audit for status.
public enum FreeText {

    /// Translate an OGC Features API free-text query into SQLite FTS5
    /// `MATCH`-clause syntax.
    ///
    /// Behaviour matches `pystac_client.free_text.parse_query_for_sqlite`:
    ///   * `+term` becomes `term`
    ///   * `-term` becomes `NOT term`
    ///   * `,` becomes `OR`
    ///   * tokens containing FTS5 special characters (`-@&:^~<>=`) get quoted,
    ///     with embedded double quotes escaped per FTS5 rules.
    public static func parseQueryForSqlite(_ q: String) -> String {
        let specialChars: Set<Character> = ["-", "@", "&", ":", "^", "~", "<", ">", "="]
        let tokens = tokenize(q)
        var out: [String] = []
        out.reserveCapacity(tokens.count)

        for raw in tokens {
            let token = raw.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if token == "," {
                out.append("OR")
            } else if token.hasPrefix("+") {
                out.append(String(token.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if token.hasPrefix("-") {
                out.append("NOT \(String(token.dropFirst()).trimmingCharacters(in: .whitespaces))")
            } else if token.contains(where: { specialChars.contains($0) }) {
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                out.append("\"\(escaped)\"")
            } else {
                out.append(token)
            }
        }
        return out.joined(separator: " ")
    }

    /// Tokenize a free-text query into:
    ///   * `"…"` quoted phrases (kept whole, quotes included),
    ///   * single `,` `(` `)` characters as standalone tokens,
    ///   * runs of non-whitespace, non-comma, non-paren characters as terms.
    ///
    /// Mirrors the Python regex `\"[^\"]*\"|,|[\(\)]|[^,\s\(\)]+`.
    private static func tokenize(_ q: String) -> [String] {
        var tokens: [String] = []
        var i = q.startIndex
        while i < q.endIndex {
            let c = q[i]
            if c.isWhitespace {
                i = q.index(after: i)
            } else if c == "\"" {
                let start = i
                let after = q.index(after: i)
                if let end = q[after...].firstIndex(of: "\"") {
                    tokens.append(String(q[start...end]))
                    i = q.index(after: end)
                } else {
                    // unterminated quote — take rest as token
                    tokens.append(String(q[start...]))
                    i = q.endIndex
                }
            } else if c == "," || c == "(" || c == ")" {
                tokens.append(String(c))
                i = q.index(after: i)
            } else {
                let start = i
                while i < q.endIndex {
                    let cc = q[i]
                    if cc.isWhitespace || cc == "," || cc == "(" || cc == ")" { break }
                    i = q.index(after: i)
                }
                tokens.append(String(q[start..<i]))
            }
        }
        return tokens
    }
}
