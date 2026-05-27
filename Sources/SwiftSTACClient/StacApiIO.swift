import Foundation
import SwiftSTAC

/// Async STAC-API-aware I/O actor. Mirrors `pystac_client.stac_api_io.StacApiIO`.
///
/// `StacApiIO` owns session-level mutable state — common headers, query
/// parameters, and a request-modifier hook — so it is implemented as an
/// `actor` to keep mutations data-race safe. Network calls go through the
/// injected ``HTTPTransport`` and are off-loaded with `nonisolated` adapters,
/// so the actor never serialises in-flight requests.
///
/// To use a custom HTTP transport for tests, pass one to `init(transport:headers:parameters:requestModifier:)`;
/// for production, the default ``URLSessionTransport`` is fine.
public actor StacApiIO {

    /// Headers merged into every outgoing request.
    public private(set) var headers: [String: String]

    /// Query parameters merged into every outgoing GET request URL.
    public private(set) var parameters: [String: String]

    /// HTTP transport executing the requests.
    public let transport: HTTPTransport

    /// Optional pre-flight hook: if non-nil, called for every request right
    /// before it's sent and may return a replacement request.
    public private(set) var requestModifier: (@Sendable (HTTPRequest) -> HTTPRequest)?

    public init(
        transport: HTTPTransport = URLSessionTransport(),
        headers: [String: String] = [:],
        parameters: [String: String] = [:],
        requestModifier: (@Sendable (HTTPRequest) -> HTTPRequest)? = nil
    ) {
        self.transport = transport
        self.headers = headers
        self.parameters = parameters
        self.requestModifier = requestModifier
    }

    /// Merge additional state into this IO. Mirrors `StacApiIO.update`.
    public func update(
        headers: [String: String]? = nil,
        parameters: [String: String]? = nil,
        requestModifier: (@Sendable (HTTPRequest) -> HTTPRequest)? = nil
    ) {
        if let headers { for (k, v) in headers { self.headers[k] = v } }
        if let parameters { for (k, v) in parameters { self.parameters[k] = v } }
        if let requestModifier { self.requestModifier = requestModifier }
    }

    // MARK: - Single requests

    /// Issue a request and return the response body as text.
    ///
    /// - Parameter href: Target URL.
    /// - Parameter method: ``HTTPMethod/GET`` or ``HTTPMethod/POST``. Defaults to GET.
    /// - Parameter parameters: For GET, merged with session parameters into the
    ///   URL's query string. For POST, sent as the JSON body.
    /// - Parameter headers: Per-call headers; merged with session headers.
    public func request(
        _ href: String,
        method: HTTPMethod = .GET,
        parameters: [String: JSONValue]? = nil,
        headers: [String: String]? = nil
    ) async throws -> String {
        let req = try buildRequest(href: href, method: method, parameters: parameters, headers: headers)
        let resp: HTTPResponse
        do {
            resp = try await transport.send(req)
        } catch let err as STACClientError {
            throw err
        } catch {
            throw STACClientError.api(statusCode: nil, message: String(describing: error))
        }
        if resp.statusCode != 200 {
            throw STACClientError.api(statusCode: resp.statusCode, message: resp.bodyText ?? "")
        }
        return resp.bodyText ?? ""
    }

    /// Issue a request and decode the body as a JSON object.
    public func readJSON(
        _ href: String,
        method: HTTPMethod = .GET,
        parameters: [String: JSONValue]? = nil,
        headers: [String: String]? = nil
    ) async throws -> [String: JSONValue] {
        let text = try await request(href, method: method, parameters: parameters, headers: headers)
        guard let data = text.data(using: .utf8) else {
            throw STACClientError.generic("Failed to encode JSON text as UTF-8")
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case let .object(o) = value else {
            throw STACClientError.generic("Top-level JSON value is not an object")
        }
        return o
    }

    // MARK: - Pagination

    /// Async stream over every page of a paginated STAC endpoint
    /// (`/collections`, `/search`, etc). Mirrors `StacApiIO.get_pages`.
    ///
    /// Each emitted dict is one page. Iteration stops when a page has no
    /// `features` (or `collections`) or there is no `next` link to follow.
    ///
    /// The stream is built lazily: page N+1 is not fetched until the consumer
    /// awaits past page N, so callers can break out early with no wasted I/O.
    public nonisolated func pages(
        _ url: String,
        method: HTTPMethod = .GET,
        parameters: [String: JSONValue]? = nil
    ) -> AsyncThrowingStream<[String: JSONValue], Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    var page = try await self.readJSON(url, method: method, parameters: parameters)
                    if !Self.pageHasResults(page) { continuation.finish(); return }
                    continuation.yield(page)

                    while let next = Self.nextLink(in: page) {
                        let nextMethod = HTTPMethod(rawValue: (next["method"]?.stringValue ?? "GET").uppercased()) ?? .GET
                        let href = next["href"]?.stringValue ?? ""
                        // POST body merging: per pystac-client, take next.body verbatim
                        // unless `merge=true`, in which case shallow-merge with parameters.
                        let body: [String: JSONValue]?
                        if nextMethod == .POST {
                            let merge = (next["merge"]?.boolValue) ?? false
                            let nextBody = next["body"]?.objectValue ?? [:]
                            if merge {
                                var merged = parameters ?? [:]
                                for (k, v) in nextBody { merged[k] = v }
                                body = merged
                            } else {
                                body = nextBody
                            }
                        } else {
                            body = nil
                        }
                        page = try await self.readJSON(href, method: nextMethod, parameters: body)
                        if !Self.pageHasResults(page) { continuation.finish(); return }
                        continuation.yield(page)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request building

    private func buildRequest(
        href: String,
        method: HTTPMethod,
        parameters: [String: JSONValue]?,
        headers: [String: String]?
    ) throws -> HTTPRequest {
        var mergedHeaders = self.headers
        if let headers { for (k, v) in headers { mergedHeaders[k] = v } }

        var req: HTTPRequest
        if method == .POST {
            mergedHeaders["Content-Type"] = mergedHeaders["Content-Type"] ?? "application/json"
            let bodyDict = parameters ?? [:]
            let bodyData = try JSONEncoder().encode(JSONValue.object(bodyDict))
            req = HTTPRequest(method: .POST, url: href, headers: mergedHeaders, body: bodyData)
        } else {
            // Merge session parameters + per-call into query string.
            var query = self.parameters
            if let parameters {
                for (k, v) in parameters { query[k] = jsonScalarToQueryString(v) }
            }
            let urlWithQuery = appendQuery(href, query: query)
            req = HTTPRequest(method: .GET, url: urlWithQuery, headers: mergedHeaders, body: nil)
        }

        if let mod = requestModifier { req = mod(req) }
        return req
    }

    private static func pageHasResults(_ page: [String: JSONValue]) -> Bool {
        if let f = page["features"]?.arrayValue, !f.isEmpty { return true }
        if let c = page["collections"]?.arrayValue, !c.isEmpty { return true }
        return false
    }

    private static func nextLink(in page: [String: JSONValue]) -> [String: JSONValue]? {
        guard let links = page["links"]?.arrayValue else { return nil }
        for link in links {
            guard case let .object(o) = link else { continue }
            if o["rel"]?.stringValue == "next" { return o }
        }
        return nil
    }
}

// MARK: - URL helpers

private func appendQuery(_ url: String, query: [String: String]) -> String {
    guard !query.isEmpty else { return url }
    var comps = URLComponents(string: url)
    var items = comps?.queryItems ?? []
    // Stable order: sorted by key so request URLs are deterministic and
    // mock stubs key off a predictable string.
    for k in query.keys.sorted() {
        items.append(URLQueryItem(name: k, value: query[k]))
    }
    comps?.queryItems = items
    return comps?.string ?? url
}

private func jsonScalarToQueryString(_ v: JSONValue) -> String {
    switch v {
    case .string(let s): return s
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .bool(let b): return b ? "true" : "false"
    case .null: return ""
    case .array, .object:
        // Encode complex parameters as JSON for transport in a GET query.
        if let data = try? JSONEncoder().encode(v),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return ""
    }
}

// MARK: - StacIO conformance

extension StacApiIO: StacIO {
    /// Read text from an HTTP(S) URL. ``StacApiIO`` is a *network* I/O actor —
    /// passing a non-URL source throws ``STACClientError/generic(_:)``. For
    /// local-file STAC reads, use `SwiftSTAC.DefaultStacIO`.
    public func readText(_ source: String) async throws -> String {
        guard HREFUtils.isURL(source) else {
            throw STACClientError.generic("StacApiIO only reads HTTP(S) URLs; got '\(source)'")
        }
        return try await self.request(source)
    }

    /// Writes are not supported — STAC API transactions are out of scope.
    public func writeText(_ text: String, to dest: String) async throws {
        throw STACClientError.api(statusCode: nil, message: "Transactions not supported")
    }
}
