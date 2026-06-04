import Foundation
import Testing

struct PackageInfoCacheTests {
    @Test
    func writePackageInfoCacheWritesRootIndexFromCachedManifest() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = root.appendingPathComponent("Package")
        let scratch = root.appendingPathComponent("scratch")
        let cacheDir = root.appendingPathComponent("package-info")
        try writeCachedManifest(emptyManifest(), packageDir: package)

        try await writePackageInfoCache(
            packageDir: package,
            scratchDir: scratch,
            resolved: ResolvedPins(originHash: "origin", pins: [], version: 3),
            cacheDir: cacheDir,
            disableSandbox: false,
            quiet: true
        )

        let indexPath = cacheDir.appendingPathComponent("index.json")
        let rootPath = cacheDir.appendingPathComponent("root.json")
        #expect(FileManager.default.fileExists(atPath: indexPath.path))
        #expect(FileManager.default.fileExists(atPath: rootPath.path))

        let index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexPath)) as? [String: Any])
        #expect(index["schema_version"] as? Int == 1)
        #expect((index["packages"] as? [[String: Any]])?.isEmpty == true)

        let rootEntry = try #require(index["root"] as? [String: Any])
        #expect(rootEntry["identity"] as? String == "root")
        #expect(rootEntry["revision"] as? String == "origin")
    }
}
