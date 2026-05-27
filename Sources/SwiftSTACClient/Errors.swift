import Foundation

/// Errors raised by ``SwiftSTACClient``.
///
/// Mirrors the union of `pystac_client.errors` and `pystac_client.exceptions`.
public enum STACClientError: Error, CustomStringConvertible, Sendable {
    /// The opened URL did not return a STAC Catalog/API root.
    case clientType(String)

    /// The server returned an unexpected response. Mirrors `pystac_client.exceptions.APIError`.
    case api(statusCode: Int?, message: String)

    /// Invalid parameters passed to a search or other API call.
    case parameters(String)

    /// The server does not advertise the required conformance class.
    case doesNotConformTo(String)

    /// A generic error wrapping an underlying message.
    case generic(String)

    public var description: String {
        switch self {
        case .clientType(let m): return "ClientTypeError: \(m)"
        case .api(let code, let m):
            if let code { return "APIError (\(code)): \(m)" }
            return "APIError: \(m)"
        case .parameters(let m): return "ParametersError: \(m)"
        case .doesNotConformTo(let name): return "DoesNotConformTo: \(name)"
        case .generic(let m): return m
        }
    }

    /// HTTP status code, if the error originated from a response.
    public var statusCode: Int? {
        if case let .api(code, _) = self { return code }
        return nil
    }
}
