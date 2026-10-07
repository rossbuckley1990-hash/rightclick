// swift-tools-version: 6.0
import PackageDescription
#if os(macOS)
let nativeMac = true
#else
let nativeMac = false
#endif
#if os(Windows)
let supportsNIO = false
#else
let supportsNIO = true
#endif
// One core and one MCP implementation. Native UI, mDNS and Keychain-only OAuth
// are host adapters, not prerequisites of the network capability runtime.
let macCoreFiles = [
    "ActionExtensionCatalog.swift", "BonjourGRPCSource.swift", "BonjourGraphQLSource.swift",
    "BonjourOpenAPISource.swift", "BundleScan.swift", "MacOSCapabilityReflectors.swift",
    "OAuthOIDCAuthority.swift", "ServiceCatalog.swift", "ServiceContext.swift", "ServiceOutcome.swift",
    "SharingCatalog.swift", "SharingExecutionModel.swift",
]
let portableCoreTests = [
    "CapabilityABITests.swift", "CapabilityABIBoundaryTests.swift", "CapabilityABIAdapterTests.swift",
    "CapabilityExperienceTests.swift", "DispatchContractBindingTests.swift", "PolicyTests.swift",
    "OpenAPIReflectorTests.swift", "GraphQLReflectorTests.swift", "CapabilityArtifactResolverTests.swift",
    "MOAT004G1AcquisitionTests.swift", "MOAT004G2SplitOriginTests.swift", "MOAT004G3ZeroArgumentGETTests.swift",
    "MOAT004G4JSONSyntaxFallbackTests.swift", "MOAT005G1PathAndJSONBodyTests.swift",
    "MOAT005G2MultiplePathArgumentsTests.swift", "MOAT005G3GitHubRequestSchemaTests.swift",
    "MOAT005G4MutationJSONResponseFallbackTests.swift", "MOAT005G5FullFrozenGitHubContractTests.swift",
    "MOAT005G6MultiSegmentPathTests.swift", "ConfiguredOpenAPISourceTests.swift",
] + (supportsNIO ? ["GRPCReflectorTests.swift", "GRPCReflectionTransportTests.swift", "CapabilityExperienceLedgerTests.swift"] : [])
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
]
var coreDependencies: [Target.Dependency] = ["RightClickARD", .product(name: "Crypto", package: "swift-crypto")]
var mcpDependencies: [Target.Dependency] = ["RightClickCore", .product(name: "MCP", package: "swift-sdk")]
    dependencies += [
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.26.2"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
    ]
if supportsNIO {
    coreDependencies += [
        .product(name: "GRPC", package: "grpc-swift"), .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"),
    ]
    mcpDependencies += [.product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOHTTP1", package: "swift-nio")]
}
var products: [Product] = [
    .library(name: "RightClickARD", targets: ["RightClickARD"]),
    .library(name: "RightClickCore", targets: ["RightClickCore"]),
    .library(name: "RightClickMCP", targets: ["RightClickMCP"]),
    .executable(name: "rightclick", targets: ["RightClickCLI"]),
    .executable(name: "rightclick-ard-probe", targets: ["RightClickARDProbe"]),
]
var targets: [Target] = [
    .target(name: "RightClickARD", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "RightClickCore", dependencies: coreDependencies,
        exclude: nativeMac ? [] : macCoreFiles, swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: nativeMac ? [.linkedFramework("AppKit")] : []),
    .target(name: "RightClickMCP", dependencies: mcpDependencies,
        exclude: nativeMac ? ["HTTPListenerNIO.swift"] : ["HTTPListener.swift"],
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: nativeMac ? [.linkedFramework("Network")] : []),
    .executableTarget(name: "RightClickCLI", dependencies: ["RightClickCore", "RightClickMCP"],
        sources: nativeMac ? nil : ["PortableMain.swift", "PortableCommands.swift", "ProviderConfigurationCLI.swift"],
        swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-parse-as-library"])]),
    .executableTarget(name: "RightClickARDProbe", dependencies: ["RightClickARD"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "RightClickARDTests", dependencies: ["RightClickARD"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "RightClickCoreTests", dependencies: ["RightClickARD", "RightClickCore"],
        sources: nativeMac ? nil : portableCoreTests, swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "RightClickPortableTests", dependencies: ["RightClickCore", "RightClickMCP"], swiftSettings: [.swiftLanguageMode(.v5)]),
]
if nativeMac {
    products += [.executable(name: "rightclick-probe", targets: ["RightClickProbe"]),
        .executable(name: "rightclick-marker", targets: ["RightClickMarker"])]
    targets += [
        .target(name: "RightClickProbePrivate", path: "Sources/RightClickProbePrivate", publicHeadersPath: "include"),
        .executableTarget(name: "RightClickProbe", dependencies: ["RightClickProbePrivate"],
            path: "Sources/RightClickProbe", swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AVFoundation")]),
        .executableTarget(name: "RightClickMarker", swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedFramework("AppKit")]),
        .testTarget(name: "RightClickCLITests", dependencies: ["RightClickCLI"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "RightClickMCPTests", dependencies: ["RightClickCore", "RightClickMCP"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
}
let package = Package(name: "rightclick-mcp", platforms: [.macOS(.v14)], products: products,
    dependencies: dependencies, targets: targets)

