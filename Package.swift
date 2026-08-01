// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hatchery",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HatcheryKit", targets: ["HatcheryKit"]),
        .executable(name: "hatchery", targets: ["hatchery"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // All logic lives here so it is reachable by tests. Frontends stay thin.
        .target(name: "HatcheryKit"),
        .executableTarget(
            name: "hatchery",
            dependencies: [
                "HatcheryKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "HatcheryKitTests", dependencies: ["HatcheryKit"]),
    ]
)
