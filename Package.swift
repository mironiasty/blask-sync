// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlaskSync",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "BlaskSync", targets: ["BlaskSync"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        // Bridge discovery, pairing and the CLIP v2 API. No UI code.
        .target(name: "HueKit"),
        // Turning screen (and later audio) content into channel colors. No UI code.
        .target(name: "SyncCore", dependencies: ["HueKit"]),
        // The menu bar app.
        .executableTarget(
            name: "BlaskSync",
            dependencies: ["HueKit", "SyncCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "HueKitTests", dependencies: ["HueKit"]),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"]),
    ]
)
