// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SwifterPM",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "SwifterPMCore", targets: ["SwifterPMCore"]),
        .executable(name: "swifterpm", targets: ["swifterpm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.7.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.99.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "0.4.0"),
        .package(
            url: "https://github.com/swiftlang/swift-package-manager.git",
            revision: "e5ac741fed39ebd16df924d3dbfa904a1c332079"
        ),
    ],
    targets: [
        .target(
            name: "SwifterPMCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .product(name: "_NIOFileSystem", package: "swift-nio"),
                .product(name: "SwiftPMDataModel-auto", package: "swift-package-manager"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            path: "Sources/swifterpm"
        ),
        .executableTarget(
            name: "swifterpm",
            dependencies: ["SwifterPMCore"],
            path: "Sources/swifterpmCLI"
        ),
        .testTarget(
            name: "SwifterPMCoreTests",
            dependencies: ["SwifterPMCore"],
            path: "Tests/swifterpmTests",
            exclude: ["main.swift"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
