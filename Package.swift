// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "rightclick-mcp",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "RightClickCore", targets: ["RightClickCore"]),
        .executable(name: "rightclick", targets: ["RightClickCLI"]),
        .executable(name: "rightclick-probe", targets: ["RightClickProbe"]),
        .executable(name: "rightclick-marker", targets: ["RightClickMarker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "RightClickCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .target(
            name: "RightClickMCP",
            dependencies: [
                "RightClickCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "RightClickCLI",
            dependencies: ["RightClickCore", "RightClickMCP"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-parse-as-library"]),
            ]
        ),
        .target(
            name: "RightClickProbePrivate",
            path: "Sources/RightClickProbePrivate",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "RightClickProbe",
            dependencies: ["RightClickProbePrivate"],
            path: "Sources/RightClickProbe",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "RightClickMarker",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "RightClickCoreTests",
            dependencies: ["RightClickCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "RightClickCLITests",
            dependencies: ["RightClickCLI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RightClickMCPTests",
            dependencies: [
                "RightClickCore",
                "RightClickMCP",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
