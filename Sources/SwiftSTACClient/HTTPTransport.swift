import Foundation

/// HTTP method used by ``StacApiIO``. Only `GET` and `POST` are used by the
/// STAC API spec.
public enum HTTPMethod: String, Sendable {
    case GET
    case POST
}

/// One side of the wire: a transport takes a fully-formed request and returns
/// status code + body bytes. Inject a ``MockHTTPTransport`` in tests to avoid
/// hitting the network. The default implementation is ``URLSessionTransport``.
public protocol HTTPTransport: Sendable {
    /// Perform a single HTTP exchange. Implementations should not retry or
    /// transform errors — ``StacApiIO`` does that.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// A request the transport will execute. Headers and parameters are
/// already merged (session-level + per-call) before reaching the transport.
public struct HTTPRequest: Sendable, Hashable {
    public var method: HTTPMethod
    public var url: String
    public var headers: [String: String]
    /// JSON-encoded body, for `POST`. For `GET`, this is empty and query
    /// parameters live in ``url``.
    public var body: Data?

    public init(method: HTTPMethod, url: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// A response from the transport.
public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var body: Data
    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    public var bodyText: String? { String(data: body, encoding: .utf8) }
}

/// Default ``HTTPTransport`` backed by `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    public var urlSession: URLSession
    public var timeout: TimeInterval?

    public init(urlSession: URLSession = .shared, timeout: TimeInterval? = nil) {
        self.urlSession = urlSession
        self.timeout = timeout
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url) else {
            throw STACClientError.generic("Invalid URL: \(request.url)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = request.method.rawValue
        if let timeout { req.timeoutInterval = timeout }
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body = request.body {
            req.httpBody = body
            if request.headers["Content-Type"] == nil {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        let (data, response) = try await urlSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResponse(statusCode: status, body: data)
    }
}

/// In-memory test transport. Keys lookups by `(method, url-without-query)` so
/// tests can stub `GET /search` once regardless of query parameter ordering;
/// use ``stubExact(_:_:status:json:)`` if you need to match the full URL with parameters.
///
/// Example:
/// ```swift
/// let mock = MockHTTPTransport()
/// await mock.stub(.GET, "https://api.example.com/", with: rootJSON)
/// await mock.stub(.POST, "https://api.example.com/search", with: searchJSON)
/// ```
public actor MockHTTPTransport: HTTPTransport {
    private struct Stub: Sendable {
        var status: Int
        var body: Data
    }

    /// Keyed by `"\(method) \(url)"`, where url has its query stripped unless
    /// the stub was registered via ``stubExact(_:_:status:json:)``.
    private var stubs: [String: Stub] = [:]
    private var exactStubs: [String: Stub] = [:]

    /// Every request the transport has been asked to send, in order.
    public private(set) var sentRequests: [HTTPRequest] = []

    public init() {}

    /// Register a JSON response. `body` is encoded as UTF-8 JSON text.
    public func stub(_ method: HTTPMethod, _ url: String, status: Int = 200, json: String) {
        stubs[key(method, url)] = Stub(status: status, body: Data(json.utf8))
    }

    /// Register a response keyed by *exact* URL (including query string).
    public func stubExact(_ method: HTTPMethod, _ url: String, status: Int = 200, json: String) {
        exactStubs[key(method, url)] = Stub(status: status, body: Data(json.utf8))
    }

    /// Register a 404 for the given path. Convenience for error-path tests.
    public func stub404(_ method: HTTPMethod, _ url: String) {
        stubs[key(method, url)] = Stub(status: 404, body: Data("Not Found".utf8))
    }

    nonisolated public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        return try await record(request)
    }

    private func record(_ request: HTTPRequest) throws -> HTTPResponse {
        sentRequests.append(request)
        let exact = key(request.method, request.url)
        if let stub = exactStubs[exact] { return HTTPResponse(statusCode: stub.status, body: stub.body) }
        let bare = key(request.method, stripQuery(request.url))
        if let stub = stubs[bare] { return HTTPResponse(statusCode: stub.status, body: stub.body) }
        throw STACClientError.generic("MockHTTPTransport: no stub for \(request.method.rawValue) \(request.url)")
    }

    private func key(_ method: HTTPMethod, _ url: String) -> String { "\(method.rawValue) \(url)" }

    private func stripQuery(_ url: String) -> String {
        if let q = url.firstIndex(of: "?") { return String(url[..<q]) }
        return url
    }
}
