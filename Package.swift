// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vitral",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VitralKit", targets: ["VitralKit"]),
        .executable(name: "vitral", targets: ["vitral"]),
        // Copied into every app Vitral makes; `vitral install` looks for it next to itself.
        .executable(name: "vitral-launcher", targets: ["VitralLauncher"]),
    ],
    targets: [
        .target(name: "VitralKit"),
        .executableTarget(name: "vitral", dependencies: ["VitralKit"]),
        .executableTarget(name: "VitralLauncher", dependencies: ["VitralKit"]),
        .testTarget(name: "VitralKitTests", dependencies: ["VitralKit"]),
    ]
)
