// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlateCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SlateCore", targets: ["SlateCore"])
    ],
    targets: [
        .target(name: "SlateCore"),
        .executableTarget(name: "ltcbench", dependencies: ["SlateCore"]),
        .executableTarget(name: "ltcplay", dependencies: ["SlateCore"]),
        // macOS only: captures from real hardware, so it needs a machine with
        // an audio interface attached rather than a simulator.
        .executableTarget(name: "ltclisten", dependencies: ["SlateCore"]),
        .testTarget(name: "SlateCoreTests", dependencies: ["SlateCore"]),
    ]
)
