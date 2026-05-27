import Foundation

/// Version metadata for ``SwiftSTACClient``. Mirrors
/// `pystac_client.version.__version__` and the `portedFrom…` pattern from
/// `SwiftSTAC.STACVersion`.
///
/// Bump ``portedFromPystacClient`` and ``portedFromPystacClientCommit`` in
/// lockstep whenever you re-sync against a newer upstream snapshot.
public enum ClientVersion {

    /// SwiftSTACClient's own SemVer.
    public static let version = "0.1.0"

    /// Version of [pystac-client](https://github.com/stac-utils/pystac-client)
    /// this port tracks. Reflects the upstream `pystac_client.__version__`
    /// at the time of the port — not the package's own ``version``.
    public static let portedFromPystacClient = "0.9.0"

    /// Upstream pystac-client git commit this port was taken from. Pinned
    /// to the exact HEAD of the local working tree at port time so we can
    /// diff future syncs precisely against it.
    public static let portedFromPystacClientCommit = "07582d0"
}
