import Foundation
import Testing

struct RestoreTests {
    @Test
    func restorePackageWithNoPinsUsesScopedScratchAndCache() async throws {
        try await withTemporaryDirectory { root in
            let scratch = root.appendingPathComponent("scratch")
            let cache = try await Cache(root: root.appendingPathComponent("cache"))

            try await WorkspaceRestorer.restorePackage(
                scratchDir: scratch,
                cache: cache,
                registryConfig: RegistryConfig(),
                resolved: ResolvedPins(originHash: nil, pins: [], version: 3),
                quiet: true
            )

            #expect(try await AsyncFileSystem.exists(scratch.appendingPathComponent("checkouts")))
            #expect(
                try await AsyncFileSystem.exists(
                    scratch.appendingPathComponent("registry/downloads")))
        }
    }

    @Test
    func writeWorkspaceStateWritesSourceControlAndRegistryDependencies() async throws {
        try await withTemporaryDirectory { root in
            let package = root.appendingPathComponent("Package")
            let scratch = root.appendingPathComponent("scratch")
            try await writeCachedManifest(emptyManifest(), packageDir: package)

            let resolved = ResolvedPins(
                originHash: "origin",
                pins: [
                    ResolvedPin(
                        identity: "foo",
                        kind: "remoteSourceControl",
                        location: "https://github.com/example/foo.git",
                        state: ResolvedState(
                            branch: nil, revision: "abcdef1234567890", version: "1.2.3")
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

            try await WorkspaceRestorer.writeWorkspaceState(
                packageDir: package, scratchDir: scratch, resolved: resolved, disableSandbox: false)

            let statePath = scratch.appendingPathComponent("workspace-state.json")
            let state = try #require(
                JSONSerialization.jsonObject(
                    with: try await AsyncFileSystem.readData(from: statePath))
                    as? [String: Any])
            let object = try #require(state["object"] as? [String: Any])
            let dependencies = try #require(object["dependencies"] as? [[String: Any]])
            #expect(dependencies.count == 2)
            #expect(
                Set(
                    dependencies.compactMap {
                        ($0["packageRef"] as? [String: Any])?["identity"] as? String
                    })
                    == ["foo", "example.package"])
        }
    }
}
