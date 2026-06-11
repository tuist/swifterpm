import Foundation
import Testing
@testable import SwifterPMCore

struct ResolveTests {
    @Test
    func defaultResolverShellsOutToSwiftPMWithoutWritingWhenRequested() async throws {
        try await withTemporaryDirectory { root in
            let dependency = root.appendingPathComponent("Dependency")
            try await writeLibraryPackageManifest(at: dependency, name: "Dependency")
            try await SystemProcess.run("git", ["init"], workingDirectory: dependency)
            try await SystemProcess.run(
                "git", ["config", "user.name", "SwifterPM Tests"], workingDirectory: dependency)
            try await SystemProcess.run(
                "git", ["config", "user.email", "tests@example.com"], workingDirectory: dependency)
            try await SystemProcess.run(
                "git", ["add", "Package.swift", "Sources"], workingDirectory: dependency)
            try await SystemProcess.run("git", ["commit", "-m", "Initial"], workingDirectory: dependency)
            try await SystemProcess.run("git", ["tag", "1.0.0"], workingDirectory: dependency)

            let package = root.appendingPathComponent("App")
            try await writeAppPackageManifest(
                at: package,
                dependencyURL: dependency.path
            )

            let cache = try await Cache(root: root.appendingPathComponent("cache"))
            let resolved = try await PackageResolver.resolve(
                packageDir: package,
                scratchDir: root.appendingPathComponent("scratch"),
                cache: cache,
                registryConfig: RegistryConfig(),
                disableSandbox: true,
                writeResolvedFile: false
            )

            let pin = try #require(resolved.pins.first)
            #expect(pin.identity == "dependency")
            #expect(pin.state.version == "1.0.0")
            let packageResolvedExists = try await fileSystem.exists(
                package.appendingPathComponent("Package.resolved").absolutePath
            )
            #expect(!packageResolvedExists)
        }
    }

    @Test
    func localSourceControlPackageLocationRequiresPackageManifest() async throws {
        try await withTemporaryDirectory { root in
            #expect(try await PackageResolver.localSourceControlPackageLocation(root.path) == nil)
            try await fileSystem.atomicWrite(
                "package manifest\n", to: root.appendingPathComponent("Package.swift"))

            #expect(
                try await PackageResolver.localSourceControlPackageLocation(root.path)?.path
                    == root.path)
            #expect(
                try await PackageResolver.sourceControlKind(location: root.path)
                    == "localSourceControl")
            #expect(
                try await PackageResolver.sourceControlKind(
                    location: "https://github.com/example/foo")
                    == "remoteSourceControl")
        }
    }

    @Test
    func localSourceControlPackageLocationAcceptsFileURLs() async throws {
        try await withTemporaryDirectory { root in
            try await fileSystem.atomicWrite(
                "package manifest\n", to: root.appendingPathComponent("Package.swift"))

            #expect(
                try await PackageResolver.localSourceControlPackageLocation(root.absoluteString)?
                    .path
                    == root.path)
        }
    }

    @Test
    func replaceSCMWithRegistryTransformsVersionedSourceControlDependencies() async throws {
        let dependencies = [
            ManifestDependency(
                identity: "swift-log",
                kind: .sourceControl,
                location: "https://github.com/apple/swift-log.git",
                requirement: .range(
                    lower: SemVer(major: 1, minor: 0, patch: 0),
                    upper: SemVer(major: 2, minor: 0, patch: 0)
                )
            ),
        ]

        let transformed = try await PackageResolver.transformedDependencies(
            dependencies,
            registryConfig: RegistryConfig(),
            scmToRegistryTransformation: .replaceSCMWithRegistry,
            registryIdentityLookup: { sourceControlURL, _ in
                #expect(sourceControlURL == "https://github.com/apple/swift-log.git")
                return ["apple.swift-log"]
            }
        )

        let dependency = try #require(transformed.first)
        #expect(dependency.identity == "apple.swift-log")
        #expect(dependency.kind == .registry)
        #expect(dependency.location == "https://github.com/apple/swift-log.git")
    }

    @Test
    func replaceSCMWithRegistryLeavesUnversionedDependenciesOnSourceControl() async throws {
        let dependencies = [
            ManifestDependency(
                identity: "swift-log",
                kind: .sourceControl,
                location: "https://github.com/apple/swift-log.git",
                requirement: .branch("main")
            ),
        ]

        let transformed = try await PackageResolver.transformedDependencies(
            dependencies,
            registryConfig: RegistryConfig(),
            scmToRegistryTransformation: .replaceSCMWithRegistry,
            registryIdentityLookup: { _, _ in
                Issue.record("branch dependencies should not perform registry lookup")
                return ["apple.swift-log"]
            }
        )

        #expect(transformed.first?.identity == "swift-log")
        #expect(transformed.first?.kind == .sourceControl)
        #expect(transformed.first?.location == "https://github.com/apple/swift-log.git")
    }

    @Test
    func useRegistryIdentityForSCMKeepsSourceControlLocation() async throws {
        let dependencies = [
            ManifestDependency(
                identity: "swift-log",
                kind: .sourceControl,
                location: "https://github.com/apple/swift-log.git",
                requirement: .exact(SemVer(major: 1, minor: 0, patch: 0))
            ),
        ]

        let transformed = try await PackageResolver.transformedDependencies(
            dependencies,
            registryConfig: RegistryConfig(),
            scmToRegistryTransformation: .useRegistryIdentityForSCM,
            registryIdentityLookup: { _, _ in ["apple.swift-log"] }
        )

        #expect(transformed.first?.identity == "apple.swift-log")
        #expect(transformed.first?.kind == .sourceControl)
        #expect(transformed.first?.location == "https://github.com/apple/swift-log.git")
    }

    private func writeLibraryPackageManifest(at packageDir: URL, name: String) async throws {
        try await fileSystem.makeDirectory(
            at: packageDir.appendingPathComponent("Sources/\(name)").absolutePath,
            options: [.createTargetParentDirectories]
        )
        try await fileSystem.atomicWrite(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "\(name)",
                products: [
                    .library(name: "\(name)", targets: ["\(name)"]),
                ],
                targets: [
                    .target(name: "\(name)"),
                ]
            )
            """,
            to: packageDir.appendingPathComponent("Package.swift")
        )
        try await fileSystem.atomicWrite(
            "public struct \(name) {}\n",
            to: packageDir.appendingPathComponent("Sources/\(name)/\(name).swift")
        )
    }

    private func writeAppPackageManifest(at packageDir: URL, dependencyURL: String) async throws {
        try await fileSystem.makeDirectory(
            at: packageDir.appendingPathComponent("Sources/App").absolutePath,
            options: [.createTargetParentDirectories]
        )
        try await fileSystem.atomicWrite(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "App",
                products: [
                    .library(name: "App", targets: ["App"]),
                ],
                dependencies: [
                    .package(url: "\(dependencyURL)", exact: "1.0.0"),
                ],
                targets: [
                    .target(name: "App", dependencies: [
                        .product(name: "Dependency", package: "Dependency"),
                    ]),
                ]
            )
            """,
            to: packageDir.appendingPathComponent("Package.swift")
        )
        try await fileSystem.atomicWrite(
            "import Dependency\npublic struct App {}\n",
            to: packageDir.appendingPathComponent("Sources/App/App.swift")
        )
    }
}
