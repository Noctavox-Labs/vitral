// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vitral",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VitralKit", targets: ["VitralKit"]),
        .executable(name: "vitral", targets: ["vitral"]),
    ],
    targets: [
        .target(name: "VitralKit"),
        .executableTarget(name: "vitral", dependencies: ["VitralKit"]),
        .testTarget(name: "VitralKitTests", dependencies: ["VitralKit"]),
    ]
)
