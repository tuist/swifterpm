import Foundation
import Testing

struct PackageInfoCacheTests {
    @Test
    func writePackageInfoCacheWritesRootIndexFromCachedManifest() async throws {
        try await withTemporaryDirectory { root in
            let package = root.appendingPathComponent("Package")
            let scratch = root.appendingPathComponent("scratch")
            let cacheDir = root.appendingPathComponent("package-info")
            try await writeCachedManifest(emptyManifest(), packageDir: package)

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
            #expect(try await AsyncFileSystem.exists(indexPath))
            #expect(try await AsyncFileSystem.exists(rootPath))

            let index = try #require(JSONSerialization.jsonObject(with: try await AsyncFileSystem.readData(from: indexPath)) as? [String: Any])
            #expect(index["schema_version"] as? Int == 1)
            #expect((index["packages"] as? [[String: Any]])?.isEmpty == true)

            let rootEntry = try #require(index["root"] as? [String: Any])
            #expect(rootEntry["identity"] as? String == "root")
            #expect(rootEntry["revision"] as? String == "origin")
        }
    }
}
