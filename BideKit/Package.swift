// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BideKit",
    // The minimum macOS version supports the concurrency APIs used by package tests.
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "BideKit", targets: ["BideKit"]),
        .library(name: "BideUI", targets: ["BideUI"]),
    ],
    targets: [
        .target(name: "BideKit"),
        // Keep shared SwiftUI views separate from the platform-independent core.
        .target(name: "BideUI", dependencies: ["BideKit"]),
        .testTarget(name: "BideKitTests", dependencies: ["BideKit"]),
    ]
)
