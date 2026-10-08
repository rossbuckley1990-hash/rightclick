// swift-tools-version: 6.2
import PackageDescription
let package = Package(name:"ReadinessControl",platforms:[.macOS(.v14)],targets:[.target(name:"Fixture"),.testTarget(name:"FixtureTests",dependencies:["Fixture"])],swiftLanguageModes:[.v5])
