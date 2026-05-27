import Foundation
import SwiftSTAC

/// A deferred query against a STAC API's `/collections` endpoint. Mirrors
/// `pystac_client.collection_search.CollectionSearch`.
///
/// When the server advertises ``ConformanceClass/COLLECTION_SEARCH`` the
/// filter parameters are forwarded server-side. Otherwise the request still
/// goes through, but client-side filtering applies the supported subset
/// (`bbox`, `datetime`, `freeText`) locally.
public struct CollectionSearch: Sendable {
    public let url: String
    public let parameters: SearchParameters
    public let io: StacApiIO
    public let collectionSearchExtensionEnabled: Bool
    public let collectionSearchFreeTextEnabled: Bool

    public init(
        url: String,
        parameters: SearchParameters,
        io: StacApiIO,
        collectionSearchExtensionEnabled: Bool,
        collectionSearchFreeTextEnabled: Bool
    ) {
        self.url = url
        self.parameters = parameters
        self.io = io
        self.collectionSearchExtensionEnabled = collectionSearchExtensionEnabled
        self.collectionSearchFreeTextEnabled = collectionSearchFreeTextEnabled
    }

    /// Async stream over every result page.
    public func pages() -> AsyncThrowingStream<[String: JSONValue], Error> {
        let pages = io.pages(url, method: .GET, parameters: parameters.asPOSTBody())
        let extEnabled = collectionSearchExtensionEnabled
        let ftEnabled = collectionSearchFreeTextEnabled
        let params = parameters
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var emitted = 0
                    for try await page in pages {
                        var p = page
                        var collections = page["collections"]?.arrayValue ?? []
                        if !extEnabled {
                            collections = collections.filter { Self.matches($0, bbox: params.bbox, datetime: params.datetime, freeText: params.freeText) }
                        } else if !ftEnabled, let q = params.freeText {
                            collections = collections.filter { Self.matches($0, bbox: nil, datetime: nil, freeText: q) }
                        }
                        if let maxItems = params.maxItems {
                            let remaining = maxItems - emitted
                            if remaining <= 0 { break }
                            if collections.count > remaining {
                                collections = Array(collections.prefix(remaining))
                            }
                        }
                        p["collections"] = .array(collections)
                        if !collections.isEmpty {
                            emitted += collections.count
                            continuation.yield(p)
                            if let maxItems = params.maxItems, emitted >= maxItems { break }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Async stream of every matched `SwiftSTAC.Collection`.
    public func collections() -> AsyncThrowingStream<Collection, Error> {
        let pages = self.pages()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await page in pages {
                        for c in page["collections"]?.arrayValue ?? [] {
                            guard case let .object(o) = c else { continue }
                            let coll = try Collection.parse(o)
                            continuation.yield(coll)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Collect every matched collection into an array.
    public func collectionList() async throws -> [Collection] {
        var out: [Collection] = []
        for try await c in collections() { out.append(c) }
        return out
    }

    /// Number of matched results. If the server doesn't advertise a count,
    /// or the search is being client-side-filtered, this iterates the full
    /// result set and returns the count.
    public func matched() async throws -> Int? {
        var iter = pages().makeAsyncIterator()
        guard let first = try await iter.next() else { return 0 }
        if collectionSearchExtensionEnabled && collectionSearchFreeTextEnabled {
            if let ctx = first["context"]?.objectValue, let m = ctx["matched"]?.intValue {
                return Int(m)
            }
            if let n = first["numberMatched"]?.intValue {
                return Int(n)
            }
        }
        var count = first["collections"]?.arrayValue?.count ?? 0
        while let page = try await iter.next() {
            count += page["collections"]?.arrayValue?.count ?? 0
        }
        return count
    }

    // MARK: - Client-side filtering

    private static func matches(
        _ collection: JSONValue,
        bbox: [Double]?,
        datetime: String?,
        freeText: String?
    ) -> Bool {
        guard case let .object(o) = collection else { return false }
        let bboxOK = bbox == nil || bboxOverlaps(o["extent"], bbox: bbox!)
        let dtOK = datetime == nil || datetimeOverlaps(o["extent"], datetime: datetime!)
        let ftOK = freeText == nil || freeTextMatches(o, q: freeText!)
        return bboxOK && dtOK && ftOK
    }

    private static func bboxOverlaps(_ extent: JSONValue?, bbox q: [Double]) -> Bool {
        guard q.count == 4,
              let extent = extent?.objectValue,
              let bboxes = extent["spatial"]?.objectValue?["bbox"]?.arrayValue
        else { return true }
        for b in bboxes {
            let arr = b.arrayValue?.compactMap { $0.doubleValue } ?? []
            guard arr.count >= 4 else { continue }
            let (xmin1, ymin1, xmax1, ymax1) = (q[0], q[1], q[2], q[3])
            let (xmin2, ymin2, xmax2, ymax2) = (arr[0], arr[1], arr[2], arr[3])
            if xmin1 <= xmax2 && xmin2 <= xmax1 && ymin1 <= ymax2 && ymin2 <= ymax1 {
                return true
            }
        }
        return false
    }

    private static func datetimeOverlaps(_ extent: JSONValue?, datetime q: String) -> Bool {
        // Conservative: if we can't parse, don't filter out.
        guard let extent = extent?.objectValue,
              let intervals = extent["temporal"]?.objectValue?["interval"]?.arrayValue
        else { return true }
        let normalized = SearchParameters.normalizeDatetime(q) ?? q
        let qParts = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let qStart = parseDateOrNil(qParts.first)
        let qEnd = parseDateOrNil(qParts.count > 1 ? qParts[1] : nil) ?? qStart
        for interval in intervals {
            let arr = interval.arrayValue ?? []
            let s = parseDateOrNil(arr.first?.stringValue)
            let e = parseDateOrNil(arr.count > 1 ? arr[1].stringValue : nil)
            if (s ?? .distantPast) <= (qEnd ?? .distantFuture)
                && (qStart ?? .distantPast) <= (e ?? .distantFuture) {
                return true
            }
        }
        return false
    }

    private static func freeTextMatches(_ collection: [String: JSONValue], q: String) -> Bool {
        // Minimal client-side fallback: case-insensitive substring across title/description/keywords.
        let needle = q.lowercased()
        for key in ["title", "description"] {
            if let s = collection[key]?.stringValue, s.lowercased().contains(needle) { return true }
        }
        if let kws = collection["keywords"]?.arrayValue {
            for k in kws {
                if let s = k.stringValue, s.lowercased().contains(needle) { return true }
            }
        }
        return false
    }

    private static func parseDateOrNil(_ s: String?) -> Date? {
        guard let s, !s.isEmpty, s != ".." else { return nil }
        return HREFUtils.stringToDate(s)
    }
}
