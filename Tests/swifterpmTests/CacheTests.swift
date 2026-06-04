import Foundation
import Testing

struct CacheTests {
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
    func initializesExpectedCacheDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try Cache(root: root)

        for path in [
            "sources",
            "archives",
            "registry/archives",
            "metadata/remotes",
            "metadata/registries",
            "locks",
            "virtual/checkouts",
        ] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        }
    }

    @Test
    func registrySourcePathRequiresResolvedVersion() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = try Cache(root: root)
        let pin = ResolvedPin(
            identity: "example.package",
            kind: "registry",
            location: "",
            state: ResolvedState(branch: nil, revision: nil, version: nil)
        )

        #expect(throws: (any Error).self) {
            try cache.sourcePath(pin: pin)
        }
    }
}
