// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftSTACClient",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "SwiftSTACClient", targets: ["SwiftSTACClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mnmly/SwiftSTAC.git", from: "0.2.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
    ],
    targets: [
        .target(
            name: "SwiftSTACClient",
            dependencies: ["SwiftSTAC"],
            path: "Sources/SwiftSTACClient"
        ),
        .testTarget(
            name: "SwiftSTACClientTests",
            dependencies: ["SwiftSTACClient", "SwiftSTAC"],
            path: "Tests/SwiftSTACClientTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
