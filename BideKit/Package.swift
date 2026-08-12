// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BideKit",
    // iOS is what ships. macOS is declared only so `swift test` builds on a
    // Mac: without a floor it defaults to 10.13, where async URLSession and
    // structured concurrency don't exist.
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "BideKit", targets: ["BideKit"]),
        .library(name: "BideUI", targets: ["BideUI"]),
    ],
    targets: [
        .target(name: "BideKit"),
        // The design system and every view shared by the app, the Messages
        // extension, and the Live Activity. Split from BideKit so the models
        // and the ETA engine stay testable without dragging SwiftUI in.
        .target(name: "BideUI", dependencies: ["BideKit"]),
        .testTarget(name: "BideKitTests", dependencies: ["BideKit"]),
    ]
)
