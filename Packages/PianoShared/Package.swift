// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PianoShared",
    platforms: [.macOS(.v15), .visionOS(.v2)],
    products: [
        .library(name: "PianoCore", targets: ["PianoCore"]),
        .library(name: "PianoLink", targets: ["PianoLink"])
    ],
    targets: [
        .target(name: "PianoCore"),
        .target(name: "PianoLink"),
        .testTarget(name: "PianoCoreTests", dependencies: ["PianoCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "PianoLinkTests", dependencies: ["PianoLink"])
    ],
    swiftLanguageModes: [.v6]
)
