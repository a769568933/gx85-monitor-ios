// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GX85Core",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "GX85Core", targets: ["GX85Core"])],
    targets: [
        .target(name: "GX85Core"),
        .testTarget(name: "GX85CoreTests", dependencies: ["GX85Core"])
    ]
)
