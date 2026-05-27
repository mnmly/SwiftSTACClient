import Foundation

/// A non-fatal client-side warning. Mirrors the `pystac_client.warnings`
/// hierarchy.
///
/// Swift has no built-in equivalent of Python's `warnings.warn`. Instead, the
/// client emits warnings via a ``WarningHandler`` callback so callers can
/// route them to logging, escalate them to errors, or silence them. The
/// default handler does nothing (matching Python's `warnings.filterwarnings("ignore")`).
public enum STACClientWarning: Sendable, Hashable, CustomStringConvertible {
    /// Server did not advertise any conformance classes.
    case noConformsTo
    /// Server does not conform to one of the listed extensions.
    case doesNotConformTo([String])
    /// A link with the given `rel` was not found on `ownerType`.
    case missingLink(rel: String, ownerType: String)
    /// Falling back to a non-API path (e.g. walking child links instead of /search).
    case fallbackToPystac
    /// Generic informational warning.
    case message(String)

    public var description: String {
        switch self {
        case .noConformsTo:
            return "Server does not advertise any conformance classes."
        case .doesNotConformTo(let names):
            return "Server does not conform to \(names.joined(separator: ", "))"
        case .missingLink(let rel, let ownerType):
            return "No link with rel='\(rel)' could be found on this \(ownerType)."
        case .fallbackToPystac:
            return "Falling back to in-memory traversal. This might be slow."
        case .message(let m):
            return m
        }
    }
}

/// A handler that receives client-side warnings.
///
/// The handler may inspect the warning and:
///   * log it,
///   * silently swallow it (the default), or
///   * `throw` to escalate it to an error — mirrors `pystac_client.warnings.strict`.
public typealias WarningHandler = @Sendable (STACClientWarning) throws -> Void

/// Process-wide warning handler. Defaults to a no-op. Set this once at
/// program start (or per test) to capture warnings.
///
/// This is an `actor` so concurrent emit/replace is safe. Use
/// ``STACWarnings/setHandler(_:)`` and ``STACWarnings/emit(_:)``.
public actor STACWarnings {
    private static let shared = STACWarnings()
    private var handler: WarningHandler = { _ in }

    private init() {}

    /// Replace the process-wide warning handler.
    public static func setHandler(_ handler: @escaping WarningHandler) async {
        await shared.set(handler)
    }

    /// Emit a warning through the current handler. Throws if the handler chose
    /// to escalate.
    public static func emit(_ warning: STACClientWarning) async throws {
        try await shared.fire(warning)
    }

    /// Strict mode: every emitted warning is rethrown as
    /// ``STACClientError/generic(_:)``. Mirrors `pystac_client.warnings.strict`.
    public static func setStrict() async {
        await shared.set { w in
            throw STACClientError.generic(String(describing: w))
        }
    }

    /// Silence every warning (the default behaviour).
    public static func setIgnore() async {
        await shared.set { _ in }
    }

    private func set(_ h: @escaping WarningHandler) { self.handler = h }
    private func fire(_ w: STACClientWarning) throws { try self.handler(w) }
}
