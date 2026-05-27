# SwiftSTACClient — agent notes

Swift port of [pystac-client](https://github.com/stac-utils/pystac-client),
sitting on top of [SwiftSTAC](https://github.com/mnmly/SwiftSTAC) ≥ 0.2.0.

## Upstream pinning

The current pystac-client snapshot is pinned in **one place** — must stay
in sync whenever you re-port from upstream:

- ``ClientVersion/portedFromPystacClient`` (tag) +
  ``ClientVersion/portedFromPystacClientCommit`` (git SHA) in
  `Sources/SwiftSTACClient/ClientVersion.swift`.

When re-syncing:

1. `cd ../python/pystac-client && git fetch && git log --oneline <pinned>..HEAD`
   to see what changed.
2. Port the deltas (skip anything in the "Deliberately out of scope" table
   below unless the reason is now obsolete).
3. Update both constants to the new tag + short SHA.
4. Bump ``ClientVersion/version`` if the change is user-visible.

## Working invariants

- **Don't redefine STAC objects.** Items / Collections / Catalogs come from
  SwiftSTAC. If a behavior on the domain type is missing, fix it in SwiftSTAC
  rather than forking it here.
- **All I/O is async.** ``StacApiIO`` is an `actor`; ``Client`` / ``ItemSearch``
  / ``CollectionSearch`` call into it via `await`. No synchronous network
  bridges.
- **No `@unchecked Sendable` on this package's own types.** SwiftSTAC's
  domain classes are not Sendable; ``Client`` and ``CollectionClient``
  inherit that non-Sendability. Anything that needs to cross task boundaries
  (``ItemSearch``, ``CollectionSearch``, ``SearchParameters``, ``HTTPRequest``,
  …) is a value type or actor and is properly Sendable.
- **Tests do not hit the network.** Use ``MockHTTPTransport`` to stub by
  `(method, url)`. Real HTTP only runs if a caller explicitly constructs a
  ``URLSessionTransport``.
- **Conformance gating mirrors pystac-client.** Methods that require an
  extension (``Client.search`` ⇒ ``ConformanceClass/ITEM_SEARCH``,
  ``Client.collectionSearch`` ⇒ COLLECTION_SEARCH or COLLECTIONS) throw
  ``STACClientError/doesNotConformTo(_:)`` if the API doesn't advertise it.

## Documentation

`SwiftSTACClient` ships DocC-generated reference docs (see
`Sources/SwiftSTACClient/Documentation.docc/` and `Scripts/build_docs.sh`).
**`///` doc comments on public/`open` symbols are published** to the
static site at https://mnmly.github.io/SwiftSTACClient/ and (if
`EMIT_LLMS_TXT=1` is used) into `docs/llms.txt`.

When you add or modify a `public` or `open` declaration:

- Write a `///` doc comment. One-sentence summary, then a paragraph if
  the *why* is non-obvious. Skip restating what the signature already
  says.
- Document each parameter with `- Parameter name:` (use the **internal**
  name when there's an external label — DocC warns otherwise).
- Cross-reference related symbols with double-backtick links, e.g.
  `` ``OtherType/method(_:)`` ``. DocC link syntax is signature-
  sensitive: `foo(_:)` and `foo(_:_:)` are different.
- For `open func` override points with empty bodies, the doc comment
  must explain *what to override it for*, *what the arguments mean*,
  and *what the default behavior is*. These methods are the API surface
  — the comment is the only spec a subclasser sees.
- When you add a new top-level symbol that belongs in the curated
  sidebar, add it under the appropriate `## Topics` group in
  `Sources/SwiftSTACClient/Documentation.docc/SwiftSTACClient.md`.
  Topics are organized by *user task*, not alphabetic order.

Verify before declaring documentation work done:

```bash
Scripts/build_docs.sh
```

Expect exit 0 and no new "doesn't exist at" or "external name used to
document parameter" warnings attributable to your changes.

## Port audit

### Ported

| pystac-client | Swift |
|---|---|
| `conformance.py` | ``ConformanceClass`` |
| `errors.py`, `exceptions.py` | ``STACClientError`` |
| `warnings.py` (types + strict/ignore) | ``STACClientWarning``, ``STACWarnings`` |
| `free_text.parse_query_for_sqlite` | ``FreeText/parseQueryForSqlite(_:)`` |
| `stac_api_io.StacApiIO` | ``StacApiIO`` (actor) + ``HTTPTransport`` |
| `client.Client.open` / conformance helpers | ``Client/open(url:transport:headers:parameters:modifier:)``, ``Client/addConformsTo(_:)``, etc. |
| `client.Client.get_collection` / `get_collections` | ``Client/getCollection(_:)``, ``Client/collections()`` |
| `client.Client.search` (POST + GET, POST 405 → GET fallback) | ``Client/search(method:maxItems:limit:ids:collections:bbox:intersects:datetime:query:filter:filterLang:sortby:fields:)`` |
| `client.Client.get_items` (ITEM_SEARCH-routed) | ``Client/getItems(ids:limit:)`` |
| `client.Client.get_search_link` | ``Client/getSearchLink()`` + ``Client/searchHref()`` |
| `_utils.call_modifier` on Items / Collections / ItemCollections | modifier callback threaded through ``ItemSearch/modifier`` and called in ``ItemSearch/items()`` / ``ItemSearch/itemCollection()`` / ``CollectionClient/getItem(_:)`` |
| `item_search.BaseSearch` (param building) | ``SearchParameters`` |
| `item_search.ItemSearch.items / pages / matched / item_collection` | ``ItemSearch/items()`` / ``ItemSearch/pages()`` / ``ItemSearch/matched()`` / ``ItemSearch/itemCollection()`` |
| `collection_client.CollectionClient.items(*ids) / get_item` | ``CollectionClient/items(ids:)`` / ``CollectionClient/getItem(_:)`` |
| `collection_search.CollectionSearch` | ``CollectionSearch`` (incl. client-side bbox/datetime/free-text fallback) |
| Datetime expansion (`2017` → `2017-01-01T00:00:00Z/2017-12-31T23:59:59Z`) | ``SearchParameters/normalizeDatetime(_:)`` |
| `next`-link following inc. POST `merge` body | ``StacApiIO/pages(_:method:parameters:)`` |

### Deliberately out of scope

| pystac-client | Reason |
|---|---|
| `cli.py` (`stac-client` CLI) | Library is the priority; CLI is per the brief out of scope. |
| `mixins.py` queryables (`/queryables`, `/collections/{id}/queryables`) | Not exercised by the unit tests; defer until a caller needs it. |
| CQL2 text parser | Pass-through only via ``FilterExpression/text(_:)``; pystac-client itself optionally relies on a separate `cql2` Python package. |
| VCR cassette replay | Superseded by ``MockHTTPTransport`` stub-by-URL — simpler infra, same coverage. |
| Retry / backoff beyond URLSession defaults | `URLSession` already does conservative retries for transient failures. Add later if a caller asks. |
| Auth helpers (Bearer, AWS SigV4, …) | Pass headers via the `headers:` parameter, or hook ``StacApiIO/requestModifier``. |
| `client.Client.get_merged_queryables` | Needs queryables endpoints first. |
| `free_text.sqlite_text_search` (SQLite FTS5) | Requires SQLite — only the translator is portable. Client-side collection-search fallback uses substring match instead. |
| `client.Client.get_items` / `get_all_items` fallback to in-memory walk | When ``ConformanceClass/ITEM_SEARCH`` is unavailable, prefer iterating via SwiftSTAC directly. |
| `Client.from_dict`, `CollectionClient.from_dict` round-trip serialization | SwiftSTAC owns object IO; the client only builds them from API responses. |

### Test coverage snapshot

57 unit tests covering: conformance matching, free-text translator,
``StacApiIO`` (headers, params, POST body, pagination incl. POST `next` with
`merge`), ``Client`` open/conformance/getCollection/search/collections/
getItems/getSearchLink/modifier paths, ``SearchParameters`` (datetime
expansion, filter-lang inference, GET rendering, limit validation),
``ItemSearch.matched`` / `maxItems` truncation / modifier on every item /
POST-405-falls-back-to-GET.

No test hits the network — every HTTP path goes through ``MockHTTPTransport``.

## Verification

```
swift build      # clean
swift test       # 51 passing
```
