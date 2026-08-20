// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hatchery",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HatcheryKit", targets: ["HatcheryKit"]),
        .library(name: "HatcheryWeb", targets: ["HatcheryWeb"]),
        .library(name: "ScanKit", targets: ["ScanKit"]),
        .executable(name: "hatchery", targets: ["hatchery"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // NIO directly rather than a web framework. The surface is a handful of routes and one
        // page; a framework adds twenty transitive packages to every build on the arm64 box in
        // exchange for routing that fits on a screen.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
    ],
    targets: [
        // All logic lives here so it is reachable by tests. Frontends stay thin.
        .target(name: "HatcheryKit"),
        // Discovery, a layer above declaration: read what a target runs and say whose it is.
        // Split so roost or a bridge can import it without the CLI or the web face.
        .target(name: "ScanKit", dependencies: ["HatcheryKit"]),
        // The web frontend, split so request handling is testable without a socket: the API maps
        // a request value to a response value, and the NIO layer only translates.
        .target(
            name: "HatcheryWeb",
            dependencies: [
                "HatcheryKit",
                "ScanKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "hatchery",
            dependencies: [
                "HatcheryKit",
                "HatcheryWeb",
                "ScanKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "HatcheryKitTests", dependencies: ["HatcheryKit"]),
        .testTarget(name: "HatcheryWebTests", dependencies: ["HatcheryWeb"]),
        .testTarget(name: "ScanKitTests", dependencies: ["ScanKit"]),
    ]
)
