// swift-tools-version: 6.2
import PackageDescription

#if os(macOS)
let nativeProducts: [Product] = [
    .library(name: "RightClickMacOS", targets: ["RightClickMacOS"]),
    .executable(name: "rightclick-probe", targets: ["RightClickProbe"]),
    .executable(name: "rightclick-marker", targets: ["RightClickMarker"]),
]
let nativeTargets: [Target] = [
    .target(name: "RightClickMacOSHost", dependencies: ["RightClickProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "RightClickMacOS", dependencies: ["RightClickProtocol", "RightClickProviders", "RightClickMacOSHost"],
            swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedFramework("AppKit")]),
    .target(name: "RightClickProbePrivate", path: "Sources/RightClickProbePrivate", publicHeadersPath: "include"),
    .executableTarget(name: "RightClickProbe", dependencies: ["RightClickProbePrivate"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AVFoundation")]),
    .executableTarget(name: "RightClickMarker", swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit")]),
    .testTarget(name: "RightClickCLITests", dependencies: ["RightClickCLI"], swiftSettings: [.swiftLanguageMode(.v5)]),
]
let cliExclusions: [String] = ["PortableMain.swift"]
let coreTestExclusions: [String] = []
#else
let nativeProducts: [Product] = []
let nativeTargets: [Target] = []
let cliExclusions = [
    "main.swift", "ChatGPTOnboardingTransaction.swift", "ChatGPTBridge.swift", "Setup.swift", "ChatGPTLiveAttestation.swift",
    "OpenAIPluginSetup.swift", "CodexClientAdapter.swift", "ChatGPTOnboarding.swift", "ChatGPTBridgeInstaller.swift",
    "OnboardingEngine.swift", "LocalOnboarding.swift", "ClaudeClientAdapter.swift", "SetupState.swift",
    "NativeRegistrationBackend.swift", "SetupAllTransaction.swift", "StableEntrypoint.swift", "BridgeRuntime.swift", "ClientRegistry.swift",
    "AuthorityConfigurationCLI.swift",
]
// These files exercise actual native Services, AppKit pasteboards, Bonjour, or
// Keychain persistence. Generic engine/authority/RCIR/security tests remain in.
let coreTestExclusions = [
    "EngineTests.swift", "ServiceContextTests.swift", "ServiceRTFUnicodeTests.swift",
    "BonjourOpenAPISourceTests.swift", "BonjourGRPCSourceTests.swift",
    "BonjourRealLifecycleAcceptanceTests.swift", "NativeServiceUnicodeLiveAcceptanceTests.swift",
    "NativeServiceUnicodeBoundaryTests.swift", "ServiceOutcomeTests.swift",
]
#endif

let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
let protocolDependencies: [Target.Dependency] = [crypto]
let providerDependencies: [Target.Dependency] = [
    "RightClickProtocol", "RightClickARD", crypto,
    .target(name: "RightClickMacOSHost", condition: .when(platforms: [.macOS])),
    .product(name: "GRPC", package: "grpc-swift"), .product(name: "SwiftProtobuf", package: "swift-protobuf"),
    .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"),
]
let coreDependencies: [Target.Dependency] = [
    "RightClickProtocol", "RightClickProviders", crypto,
    .target(name: "RightClickMacOS", condition: .when(platforms: [.macOS])),
]
let testDependencies: [Target.Dependency] = [
    "RightClickARD", "RightClickCore", "RightClickProtocol", "RightClickProviders", crypto,
    .target(name: "RightClickMacOS", condition: .when(platforms: [.macOS])),
    .target(name: "RightClickMacOSHost", condition: .when(platforms: [.macOS])),
]
let package = Package(
    name: "rightclick-mcp", platforms: [.macOS(.v14)],
    products: [
        .library(name: "RightClickARD", targets: ["RightClickARD"]),
        .library(name: "RightClickProtocol", targets: ["RightClickProtocol"]),
        .library(name: "RightClickCore", targets: ["RightClickCore"]),
        .executable(name: "rightclick", targets: ["RightClickCLI"]),
        .executable(name: "rightclick-ard-probe", targets: ["RightClickARDProbe"]),
    ] + nativeProducts,
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.26.2"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.0"),
    ],
    targets: [
        .target(name: "RightClickARD", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RightClickProtocol", dependencies: protocolDependencies, swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RightClickProviders", dependencies: providerDependencies, swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RightClickCore", dependencies: coreDependencies, swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RightClickMCP", dependencies: ["RightClickCore", crypto,
            .product(name: "MCP", package: "swift-sdk"), .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio")], swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Network", .when(platforms: [.macOS]))]),
        .executableTarget(name: "RightClickCLI", dependencies: ["RightClickCore", "RightClickMCP"], exclude: cliExclusions,
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-parse-as-library"])]),
        .executableTarget(name: "RightClickARDProbe", dependencies: ["RightClickARD"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "RightClickARDTests", dependencies: ["RightClickARD"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "RightClickCoreTests", dependencies: testDependencies, exclude: coreTestExclusions,
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "RightClickMCPTests", dependencies: testDependencies + ["RightClickMCP"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ] + nativeTargets
)
