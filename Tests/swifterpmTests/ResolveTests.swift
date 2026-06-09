import Foundation
import Testing
@testable import SwifterPMCore

struct ResolveTests {
    @Test
    func localSourceControlPackageLocationRequiresPackageManifest() async throws {
        try await withTemporaryDirectory { root in
            #expect(try await PackageResolver.localSourceControlPackageLocation(root.path) == nil)
            try await AsyncFileSystem.atomicWrite(
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
            try await AsyncFileSystem.atomicWrite(
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
}
