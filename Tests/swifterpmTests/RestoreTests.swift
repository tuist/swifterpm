import Foundation
import Testing

struct RestoreTests {
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

    @Test
    func writeWorkspaceStateWritesSourceControlAndRegistryDependencies() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = root.appendingPathComponent("Package")
        let scratch = root.appendingPathComponent("scratch")
        try writeCachedManifest(emptyManifest(), packageDir: package)

        let resolved = ResolvedPins(
            originHash: "origin",
            pins: [
                ResolvedPin(
                    identity: "foo",
                    kind: "remoteSourceControl",
                    location: "https://github.com/example/foo.git",
                    state: ResolvedState(branch: nil, revision: "abcdef1234567890", version: "1.2.3")
                ),
                ResolvedPin(
                    identity: "example.package",
                    kind: "registry",
                    location: "",
                    state: ResolvedState(branch: nil, revision: nil, version: "2.3.4")
                ),
            ],
            version: 3
        )

        try writeWorkspaceState(packageDir: package, scratchDir: scratch, resolved: resolved, disableSandbox: false)

        let statePath = scratch.appendingPathComponent("workspace-state.json")
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: statePath)) as? [String: Any])
        let object = try #require(state["object"] as? [String: Any])
        let dependencies = try #require(object["dependencies"] as? [[String: Any]])
        #expect(dependencies.count == 2)
        #expect(Set(dependencies.compactMap { ($0["packageRef"] as? [String: Any])?["identity"] as? String }) == ["foo", "example.package"])
    }
}
