// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-simslim",
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        .library(name: "SimSlimCore", targets: ["SimSlimCore"]),
        .executable(name: "simslim", targets: ["SimSlimCLI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            exact: "1.8.2"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git",
            exact: "1.0.0"
        ),
    ],
    targets: [
        .target(
            name: "SimSlimCore",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]
        ),
        .executableTarget(
            name: "SimSlimCLI",
            dependencies: [
                "SimSlimCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SimSlimCoreTests",
            dependencies: ["SimSlimCore"]
        ),
        .testTarget(
            name: "SimSlimCLITests",
            dependencies: ["SimSlimCLI", "SimSlimCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
