// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BideKit",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "BideKit", targets: ["BideKit"])
    ],
    targets: [
        .target(name: "BideKit"),
        .testTarget(name: "BideKitTests", dependencies: ["BideKit"]),
    ]
)
