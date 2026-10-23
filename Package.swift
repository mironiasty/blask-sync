// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlaskSync",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "BlaskSync", targets: ["BlaskSync"]),
    ],
    targets: [
        // Bridge discovery, pairing and the CLIP v2 API. No UI code.
        .target(name: "HueKit"),
        // The menu bar app.
        .executableTarget(name: "BlaskSync", dependencies: ["HueKit"]),
        .testTarget(name: "HueKitTests", dependencies: ["HueKit"]),
    ]
)
