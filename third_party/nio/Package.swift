// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SwifterPMNIODeps",
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.99.0"),
    ],
    targets: [
        .target(
            name: "SwifterPMNIODeps",
            dependencies: [
                .product(name: "_NIOFileSystem", package: "swift-nio"),
            ]
        ),
    ]
)
