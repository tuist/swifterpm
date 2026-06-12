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
    func replaceSCMWithRegistryPreparesMaterializedRepositoryAndRegistryPinOverride() async throws {
        try await withTemporaryDirectory { root in
            let package = root.appendingPathComponent("App")
            let workspace = root.appendingPathComponent("workspace")
            let cache = try await Cache(root: root.appendingPathComponent("cache"))
            let repository = workspace.appendingPathComponent("registry-repositories/apple.swift-log")
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

            let prepared = try await PackageResolver.registryPreparedDependencies(
                dependencies,
                packageDir: package,
                workspace: workspace,
                cache: cache,
                registryConfig: RegistryConfig(),
                scmToRegistryTransformation: .replaceSCMWithRegistry,
                client: PackageResolver.RegistryPreparationClient(
                    identifiers: { sourceControlURL, _ in
                        #expect(sourceControlURL == "https://github.com/apple/swift-log.git")
                        return ["apple.swift-log"]
                    },
                    versions: { identity, _, _ in
                        #expect(identity == "apple.swift-log")
                        return [
                            RegistryVersion(version: "0.9.0"),
                            RegistryVersion(version: "1.0.0"),
                            RegistryVersion(version: "1.2.3"),
                            RegistryVersion(version: "2.0.0"),
                        ]
                    },
                    writeRegistryRepository: { identity, versions, requirement, workspace, _, _ in
                        #expect(identity == "apple.swift-log")
                        #expect(versions.map(\.version) == ["1.0.0", "1.2.3"])
                        #expect(workspace == root.appendingPathComponent("workspace"))
                        if case .range(let lower, let upper) = requirement {
                            #expect(lower.description == "1.0.0")
                            #expect(upper.description == "2.0.0")
                        } else {
                            Issue.record("expected a version range requirement")
                        }
                        return ManifestDependency(
                            identity: identity,
                            kind: .sourceControl,
                            location: repository.path,
                            requirement: requirement
                        )
                    }
                )
            )

            let dependency = try #require(prepared.dependencies.first)
            #expect(dependency.identity == "apple.swift-log")
            #expect(dependency.kind == .sourceControl)
            #expect(dependency.location == repository.path)
            let override = try #require(prepared.pinOverrides[repository.path])
            guard case .registry(let identity) = override else {
                Issue.record("expected a registry pin override")
                return
            }
            #expect(identity == "apple.swift-log")
        }
    }

    @Test
    func replaceSCMWithRegistryFallsBackToSourceControlIdentityWhenNoRegistryVersionMatches()
        async throws
    {
        try await withTemporaryDirectory { root in
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

            let prepared = try await PackageResolver.registryPreparedDependencies(
                dependencies,
                packageDir: root.appendingPathComponent("App"),
                workspace: root.appendingPathComponent("workspace"),
                cache: try await Cache(root: root.appendingPathComponent("cache")),
                registryConfig: RegistryConfig(),
                scmToRegistryTransformation: .replaceSCMWithRegistry,
                client: PackageResolver.RegistryPreparationClient(
                    identifiers: { _, _ in ["apple.swift-log"] },
                    versions: { _, _, _ in [RegistryVersion(version: "2.0.0")] },
                    writeRegistryRepository: { _, _, _, _, _, _ in
                        Issue.record("incompatible registry versions should not be materialized")
                        return dependencies[0]
                    }
                )
            )

            let dependency = try #require(prepared.dependencies.first)
            #expect(dependency.identity == "apple.swift-log")
            #expect(dependency.kind == .sourceControl)
            #expect(dependency.location == "https://github.com/apple/swift-log.git")
            let override = try #require(
                prepared.pinOverrides["https://github.com/apple/swift-log.git"])
            guard case .sourceControlIdentity(let identity) = override else {
                Issue.record("expected a source-control identity pin override")
                return
            }
            #expect(identity == "apple.swift-log")
        }
    }

    @Test
    func replaceSCMWithRegistryLeavesUnversionedDependenciesOnSourceControl() async throws {
        try await withTemporaryDirectory { root in
            let dependencies = [
                ManifestDependency(
                    identity: "swift-log",
                    kind: .sourceControl,
                    location: "https://github.com/apple/swift-log.git",
                    requirement: .branch("main")
                ),
            ]

            let prepared = try await PackageResolver.registryPreparedDependencies(
                dependencies,
                packageDir: root.appendingPathComponent("App"),
                workspace: root.appendingPathComponent("workspace"),
                cache: try await Cache(root: root.appendingPathComponent("cache")),
                registryConfig: RegistryConfig(),
                scmToRegistryTransformation: .replaceSCMWithRegistry,
                client: PackageResolver.RegistryPreparationClient(
                    identifiers: { _, _ in
                        Issue.record("branch dependencies should not perform registry lookup")
                        return ["apple.swift-log"]
                    },
                    versions: { _, _, _ in [] },
                    writeRegistryRepository: { _, _, _, _, _, _ in dependencies[0] }
                )
            )

            #expect(prepared.dependencies.first?.identity == "swift-log")
            #expect(prepared.dependencies.first?.kind == .sourceControl)
            #expect(
                prepared.dependencies.first?.location == "https://github.com/apple/swift-log.git")
            #expect(prepared.pinOverrides.isEmpty)
        }
    }

    @Test
    func resolveOrLoadReportsAClearErrorWhenReadOnlyAndPackageResolvedIsMissing() async throws {
        // Pre-PR the readOnly branch fell into `ResolvedFile.read`, which
        // surfaced a low-level `no such file` from the filesystem layer with no
        // hint that --force-resolved-versions was the cause. Verify the
        // domain-specific error replaces it.
        try await withTemporaryDirectory { root in
            let cache = try await Cache(root: root.appendingPathComponent("cache"))
            await #expect(throws: ToolError.self) {
                try await PackageResolver.resolveOrLoad(
                    packageDir: root,
                    cache: cache,
                    registryConfig: RegistryConfig(),
                    disableSandbox: true,
                    scmToRegistryTransformation: .disabled,
                    preferResolvedFile: true,
                    readOnly: true,
                    skipUpdate: false,
                    writeResolvedFile: false,
                    progress: nil
                )
            }
        }
    }

    @Test
    func useRegistryIdentityForSCMKeepsSourceControlLocationAndAddsPinOverride() async throws {
        try await withTemporaryDirectory { root in
            let dependencies = [
                ManifestDependency(
                    identity: "swift-log",
                    kind: .sourceControl,
                    location: "https://github.com/apple/swift-log.git",
                    requirement: .exact(SemVer(major: 1, minor: 0, patch: 0))
                ),
            ]

            let prepared = try await PackageResolver.registryPreparedDependencies(
                dependencies,
                packageDir: root.appendingPathComponent("App"),
                workspace: root.appendingPathComponent("workspace"),
                cache: try await Cache(root: root.appendingPathComponent("cache")),
                registryConfig: RegistryConfig(),
                scmToRegistryTransformation: .useRegistryIdentityForSCM,
                client: PackageResolver.RegistryPreparationClient(
                    identifiers: { _, _ in ["apple.swift-log"] },
                    versions: { _, _, _ in
                        Issue.record("use-registry-identity should not fetch registry versions")
                        return []
                    },
                    writeRegistryRepository: { _, _, _, _, _, _ in
                        Issue.record("use-registry-identity should not materialize registry repos")
                        return dependencies[0]
                    }
                )
            )

            #expect(prepared.dependencies.first?.identity == "apple.swift-log")
            #expect(prepared.dependencies.first?.kind == .sourceControl)
            #expect(
                prepared.dependencies.first?.location == "https://github.com/apple/swift-log.git")
            let override = try #require(
                prepared.pinOverrides["https://github.com/apple/swift-log.git"])
            guard case .sourceControlIdentity(let identity) = override else {
                Issue.record("expected a source-control identity pin override")
                return
            }
            #expect(identity == "apple.swift-log")
        }
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
