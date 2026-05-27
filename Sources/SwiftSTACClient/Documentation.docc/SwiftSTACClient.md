#  ``SwiftSTACClient``

A Swift client for the STAC API spec — a port of pystac-client.

See the [STAC API spec](https://github.com/radiantearth/stac-api-spec) and
upstream [pystac-client](https://github.com/stac-utils/pystac-client) for
the source-of-truth definitions this package follows.

## Overview

`SwiftSTACClient` adds an async HTTP client on top of the domain types defined
in [`SwiftSTAC`](https://github.com/mnmly/SwiftSTAC). It opens a STAC API by
its landing page URL, follows `data`/`search`/`collections` links, and returns
`SwiftSTAC.Item` / `SwiftSTAC.Collection` instances.

```swift
import SwiftSTACClient

let client = try await Client.open(url: "https://earth-search.aws.element84.com/v1")

if client.conformsTo(.ITEM_SEARCH) {
    let search = try client.search(
        bbox: [-122.5, 47.5, -122.3, 47.7],
        datetime: "2024-06",
        collections: ["sentinel-2-l2a"],
        limit: 50
    )
    for try await item in search.items() {
        print(item.id)
    }
}
```

## Topics

### Opening an API

- ``Client``
- ``ConformanceClass``

### Searching

- ``ItemSearch``
- ``CollectionSearch``
- ``SearchParameters``
- ``FilterExpression``
- ``SortSpec``
- ``FieldsSelector``

### Collections

- ``CollectionClient``

### Networking

- ``StacApiIO``
- ``HTTPTransport``
- ``URLSessionTransport``
- ``MockHTTPTransport``
- ``HTTPRequest``
- ``HTTPResponse``
- ``HTTPMethod``

### Errors and warnings

- ``STACClientError``
- ``STACClientWarning``
- ``STACWarnings``
- ``WarningHandler``

### Free-text query

- ``FreeText``

### Version

- ``ClientVersion``
