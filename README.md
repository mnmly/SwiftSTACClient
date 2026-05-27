# SwiftSTACClient

Swift client for the [STAC API spec](https://github.com/radiantearth/stac-api-spec).
Port of [pystac-client](https://github.com/stac-utils/pystac-client).

Built on top of [SwiftSTAC](https://github.com/mnmly/SwiftSTAC) — this package
adds the HTTP layer, conformance-aware dispatch, paginated search, and the
`/collections` and `/search` endpoints. STAC domain types (Item, Collection,
Catalog, Link, …) come from SwiftSTAC.

## Quick start

```swift
import SwiftSTACClient

let client = try await Client.open(url: "https://earth-search.aws.element84.com/v1")

guard client.conformsTo(.ITEM_SEARCH) else { return }

let search = try client.search(
    bbox: [-122.5, 47.5, -122.3, 47.7],
    datetime: "2024-06",
    collections: ["sentinel-2-l2a"],
    limit: 50
)

for try await item in search.items() {
    print(item.id)
}
```

## Architecture

| Type | Role |
|------|------|
| ``Client`` | API entry point; subclasses `SwiftSTAC.Catalog`. |
| ``StacApiIO`` | Actor owning headers, parameters, and an ``HTTPTransport``. |
| ``HTTPTransport`` | Wire-level protocol; ``URLSessionTransport`` for prod, ``MockHTTPTransport`` for tests. |
| ``ItemSearch`` / ``CollectionSearch`` | Sendable value types holding query params + the IO actor. Lazy: no request until you iterate. |
| ``CollectionClient`` | `SwiftSTAC.Collection` augmented with API-backed `items()` / `getItem`. |
| ``ConformanceClass`` | Conformance URIs + matching helpers. |
| ``STACClientError`` | API, parameters, conformance, and client-type errors. |
| ``STACWarnings`` | Process-wide handler for non-fatal warnings. |

### Concurrency

- All I/O is `async throws`. No semaphores, no main-actor coupling.
- ``StacApiIO`` is an **actor** — concurrent reads/writes of session state are safe.
- Pagination is exposed as `AsyncThrowingStream`; consumers can break out early.
- ``Client`` and ``CollectionClient`` are **not** `Sendable` (they inherit
  from non-Sendable SwiftSTAC classes). Own them within a single task
  hierarchy. The ``StacApiIO`` actor and ``ItemSearch`` / ``CollectionSearch``
  values are Sendable and freely shared.

### Testing without HTTP

Inject ``MockHTTPTransport`` to stub responses by URL — no `URLProtocol`
gymnastics, no cassette replay:

```swift
let mock = MockHTTPTransport()
await mock.stub(.GET, "https://api.example.com/",
                json: #"{"type":"Catalog","id":"x","description":"","conformsTo":[],"links":[]}"#)
let client = try await Client.open(url: "https://api.example.com/", transport: mock)
```

## Scope and limits

Ported:

- ``Client.open`` + conformance helpers (`addConformsTo`, `removeConformsTo`, …)
- ``Client.getCollection`` / ``Client.collections``
- ``Client.search`` — bbox, datetime expansion, ids, intersects, collections,
  query, filter (CQL2-JSON and CQL2-text passthrough), sortby, fields, limit, max_items
- ``ItemSearch.items`` / ``pages`` / ``itemCollection`` / ``matched``
- ``CollectionSearch`` with client-side filter fallback (bbox / datetime /
  free-text substring)
- ``StacApiIO`` with paginated `next`-link following, including POST `merge` bodies
- ``ConformanceClass`` with `valid_uri` matching
- ``FreeText.parseQueryForSqlite`` translator

**Intentionally deferred** (PRs welcome — file an issue first):

- `stac-client` CLI (`pystac_client/cli.py`)
- CQL2 text parser. Pass text expressions through as ``FilterExpression/text(_:)``;
  the dict form is built/serialised verbatim.
- VCR cassette replay. The ``MockHTTPTransport`` stub-by-URL model is the
  Swift equivalent.
- Retry / backoff policy beyond URLSession defaults.
- Authentication helpers. Set `Authorization` via the `headers:` parameter.
- Queryables endpoint (`/queryables`, `/collections/{id}/queryables`).
- SQLite FTS5 free-text search for client-side fallback — only the query
  *translator* is ported. Collection-side free-text fallback uses a simple
  case-insensitive substring match instead.

## Compatibility with pystac-client

Each SwiftSTACClient release pins the upstream pystac-client version it tracks.
The mapping is also available at runtime:

```swift
ClientVersion.portedFromPystacClient        // "0.9.0"
ClientVersion.portedFromPystacClientCommit  // "07582d0"
```

| SwiftSTACClient | pystac-client | Upstream commit |
| --------------- | ------------- | --------------- |
| 0.1.x           | 0.9.0         | `07582d0`       |

(The pinned commit is 62 commits past the `v0.9.0` tag — pystac-client's
own `__version__` hasn't been bumped past 0.9.0 yet at that SHA.)

## Requirements

- Swift 5.10+ tooling
- macOS 13 / iOS 16 / tvOS 16 / watchOS 9
- [SwiftSTAC](https://github.com/mnmly/SwiftSTAC) 0.2.0+

## Documentation

DocC site is built via the standard plugin:

```
swift package --allow-writing-to-directory docs \
    generate-documentation --target SwiftSTACClient \
    --output-path docs --hosting-base-path SwiftSTACClient
```

## License

Apache 2.0. See `NOTICE` for upstream attribution.
