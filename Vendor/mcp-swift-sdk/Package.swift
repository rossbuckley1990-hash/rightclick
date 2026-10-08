// swift-tools-version: 6.1
import PackageDescription

// Pinned upstream SDK snapshot; see UPSTREAM.md for provenance and the host fix.
let package = Package(
    name: "mcp-swift-sdk",
    platforms: [.macOS(.v13)],
    products: [.library(name: "MCP", targets: ["MCP"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-system.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/mattt/eventsource.git", from: "1.1.0"),
    ],
    targets: [
        .target(name: "MCP", dependencies: [
            .product(name: "SystemPackage", package: "swift-system"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "EventSource", package: "eventsource", condition: .when(platforms: [.macOS])),
        ], swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]),
    ]
)
