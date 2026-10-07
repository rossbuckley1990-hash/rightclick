// swift-tools-version: 6.0
import PackageDescription

#if os(macOS)
let nativeProducts: [Product] = [
    .executable(name: "rightclick-probe", targets: ["RightClickProbe"]),
    .executable(name: "rightclick-marker", targets: ["RightClickMarker"]),
]
let nativeTargets: [Target] = [
    .target(name: "RightClickProbePrivate", path: "Sources/RightClickProbePrivate", publicHeadersPath: "include"),
    .executableTarget(name: "RightClickProbe", dependencies: ["RightClickProbePrivate"],
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: [.linkedFramework("AppKit", .when(platforms: [.macOS])), .linkedFramework("AVFoundation")]),
    .executableTarget(name: "RightClickMarker", swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: [.linkedFramework("AppKit")]),
    .testTarget(name: "RightClickCLITests", dependencies: ["RightClickCLI"], swiftSettings: [.swiftLanguageMode(.v5)]),
]
let cliExclusions: [String] = []
let coreTestExclusions: [String] = []
#else
let nativeProducts: [Product] = []
let nativeTargets: [Target] = []
let cliExclusions = [
    "ChatGPTOnboardingTransaction.swift", "ChatGPTBridge.swift", "Setup.swift", "ChatGPTLiveAttestation.swift",
    "OpenAIPluginSetup.swift", "CodexClientAdapter.swift", "ChatGPTOnboarding.swift", "ChatGPTBridgeInstaller.swift",
    "OnboardingEngine.swift", "LocalOnboarding.swift", "ClaudeClientAdapter.swift", "SetupState.swift",
    "NativeRegistrationBackend.swift", "SetupAllTransaction.swift", "StableEntrypoint.swift", "BridgeRuntime.swift", "ClientRegistry.swift",
]
let coreTestExclusions = [
    "AcquisitionTests.swift", "EngineTests.swift", "ServiceContextTests.swift", "OutcomeVerifierTests.swift",
    "BonjourOpenAPISourceTests.swift", "BonjourGRPCSourceTests.swift",
    "BonjourRealLifecycleAcceptanceTests.swift", "MOAT004G5ExternalBearerAuthorityTests.swift",
    "OpenAPIAuthorityManagementTests.swift",
]
#endif
#if os(Windows)
let hostTestExclusions = ["CapabilityExperienceLedgerTests.swift", "RCIRProductionDispatchTests.swift", "GRPCReflectorTests.swift", "GRPCReflectionTransportTests.swift", "GRPCRealProviderAcceptanceTests.swift"]
#else
let hostTestExclusions: [String] = []
#endif

let package = Package(
    name: "rightclick-mcp",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "RightClickARD", targets: ["RightClickARD"]),
        .library(name: "RightClickCore", targets: ["RightClickCore"]),
        .executable(name: "rightclick", targets: ["RightClickCLI"]),
        .executable(name: "rightclick-ard-probe", targets: ["RightClickARDProbe"]),
    ] + nativeProducts,
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.26.2"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "RightClickARD",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "RightClickCore",
            dependencies: [
                "RightClickARD",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRPC", package: "grpc-swift", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "RightClickMCP",
            dependencies: [
                "RightClickCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "RightClickCLI",
            dependencies: ["RightClickCore", "RightClickMCP"],
            exclude: cliExclusions,
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-parse-as-library"]),
            ]
        ),
        .executableTarget(
            name: "RightClickARDProbe",
            dependencies: ["RightClickARD"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "RightClickARDTests",
            dependencies: ["RightClickARD"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "RightClickCoreTests",
            dependencies: ["RightClickARD", "RightClickCore"],
            exclude: coreTestExclusions + hostTestExclusions,
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
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
    ] + nativeTargets
)
