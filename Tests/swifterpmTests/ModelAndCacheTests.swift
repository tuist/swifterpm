import Foundation
import Testing

struct ModelAndCacheTests {
    @Test
    func semanticVersionsIgnoreBuildMetadataAndOrderPrereleasesBeforeReleases() throws {
        #expect(try SemVer("1.2.3+build.7").description == "1.2.3")
        #expect(try SemVer("1.2.3-alpha") < SemVer("1.2.3"))
        #expect(try SemVer("1.2.3") < SemVer("1.2.4"))
    }

    @Test
    func resolvedPinHelpersValidateRequiredState() throws {
        let pin = ResolvedPin(
            identity: "foo",
            kind: "remoteSourceControl",
            location: "https://github.com/example/foo.git",
            state: ResolvedState(
                branch: nil,
                revision: "abcdef1234567890",
                version: "1.2.3"
            )
        )

        #expect(try pin.revision() == "abcdef1234567890")
        #expect(try pin.versionString() == "1.2.3")
        #expect(checkoutDirectoryName(pin) == "foo")

        #expect(throws: (any Error).self) {
            try ResolvedPin(
                identity: "bar",
                kind: "remoteSourceControl",
                location: "https://github.com/example/bar",
                state: ResolvedState(branch: nil, revision: nil, version: "1.0.0")
            ).revision()
        }
    }

    @Test
    func registryIdentityAndDownloadSubpathHelpers() throws {
        let (scope, name) = try registryIdentityParts("example.package")
        #expect(scope == "example")
        #expect(name == "package")

        let pin = ResolvedPin(
            identity: "example.package",
            kind: "registry",
            location: "",
            state: ResolvedState(branch: nil, revision: nil, version: "1.2.3")
        )
        #expect(try registryDownloadSubpath(pin) == "example/package/1.2.3")
        #expect(throws: (any Error).self) {
            try registryIdentityParts("unscoped")
        }
    }

    @Test
    func cachePathsStayUnderProvidedRoot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = try Cache(root: root)
        let pin = ResolvedPin(
            identity: "foo",
            kind: "remoteSourceControl",
            location: "https://github.com/example/foo.git",
            state: ResolvedState(
                branch: nil,
                revision: "abcdef1234567890",
                version: "1.2.3"
            )
        )

        #expect(try cache.sourcePath(pin: pin).path.hasPrefix(root.path))
        #expect(cache.archivePath(url: pin.location, revision: try pin.revision()).path.hasPrefix(root.path))
        #expect(cache.remoteVersionsPath(location: pin.location).path.hasPrefix(root.path))
        #expect(cache.registryArchivePath(identity: "example.package", version: "1.2.3").path.hasPrefix(root.path))
        #expect(cache.registryVersionsPath(registryURL: "https://registry.example.com", identity: "example.package").path.hasPrefix(root.path))
    }

    @Test
    func localSourceControlPackageLocationRequiresPackageManifest() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(localSourceControlPackageLocation(root.path) == nil)
        try "package manifest\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        #expect(localSourceControlPackageLocation(root.path)?.path == root.path)
        #expect(sourceControlKind(location: root.path) == "localSourceControl")
        #expect(sourceControlKind(location: "https://github.com/example/foo") == "remoteSourceControl")
    }

    @Test
    func readAndWriteResolvedFileRoundTripsInsidePackageDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = ResolvedPins(
            originHash: "origin",
            pins: [
                ResolvedPin(
                    identity: "foo",
                    kind: "remoteSourceControl",
                    location: "https://github.com/example/foo",
                    state: ResolvedState(branch: nil, revision: "abcdef123456", version: "1.0.0")
                ),
            ],
            version: 3
        )

        try writeResolvedFile(packageDir: root, resolved: resolved)
        #expect(try readResolvedFile(packageDir: root).pins == resolved.pins)
        #expect(try readResolvedFile(packageDir: root).originHash == "origin")
    }

    @Test
    func restorePackageWithNoPinsUsesScopedScratchAndCache() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let scratch = root.appendingPathComponent("scratch")
        let cache = try Cache(root: root.appendingPathComponent("cache"))

        try await restorePackage(
            scratchDir: scratch,
            cache: cache,
            registryConfig: RegistryConfig(),
            resolved: ResolvedPins(originHash: nil, pins: [], version: 3),
            quiet: true
        )

        #expect(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("checkouts").path))
        #expect(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("registry/downloads").path))
    }
}

func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("swifterpm-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
