// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]

let package = Package(
    name: "CanopyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CanopyCore", targets: ["CanopyCore"]),
        .executable(name: "canopy-tool", targets: ["canopy-tool"]),
    ],
    targets: [
        .target(
            name: "CanopyCore",
            resources: [.process("Resources")],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "canopy-tool",
            dependencies: ["CanopyCore"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "CanopyCoreTests",
            dependencies: ["CanopyCore"],
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
