// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SwifterPMNIODeps",
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.99.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "0.4.0"),
        .package(
            url: "https://github.com/swiftlang/swift-package-manager.git",
            revision: "e5ac741fed39ebd16df924d3dbfa904a1c332079"
        ),
    ],
    targets: [
        .target(
            name: "SwifterPMNIODeps",
            dependencies: [
                .product(name: "_NIOFileSystem", package: "swift-nio"),
                .product(name: "SwiftPMDataModel-auto", package: "swift-package-manager"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]
        ),
    ]
)
