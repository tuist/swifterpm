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
                            branch: nil, revision: "abcdef1234567890", version: "1.2.3"
                        )
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
                packageDir: package, scratchDir: scratch, resolved: resolved, disableSandbox: false
            )

            let statePath = scratch.appendingPathComponent("workspace-state.json")
            let state = try #require(
                try JSONSerialization.jsonObject(
                    with: await AsyncFileSystem.readData(from: statePath))
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

    @Test
    func writeWorkspaceStateDiscoversArtifactsWhenArtifactsRootExists() async throws {
        try await withTemporaryDirectory { root in
            let package = root.appendingPathComponent("Package")
            let scratch = root.appendingPathComponent("scratch")
            try await writeCachedManifest(emptyManifest(), packageDir: package)
            try await AsyncFileSystem.createDirectory(
                at: scratch.appendingPathComponent("artifacts/foo/Foo.xcframework"),
                withIntermediateDirectories: true
            )

            let resolved = ResolvedPins(
                originHash: "origin",
                pins: [
                    ResolvedPin(
                        identity: "foo",
                        kind: "remoteSourceControl",
                        location: "https://github.com/example/foo.git",
                        state: ResolvedState(
                            branch: nil, revision: "abcdef1234567890", version: "1.2.3"
                        )
                    ),
                ],
                version: 3
            )

            try await WorkspaceRestorer.writeWorkspaceState(
                packageDir: package, scratchDir: scratch, resolved: resolved, disableSandbox: false
            )

            let statePath = scratch.appendingPathComponent("workspace-state.json")
            let state = try #require(
                try JSONSerialization.jsonObject(
                    with: await AsyncFileSystem.readData(from: statePath))
                    as? [String: Any])
            let object = try #require(state["object"] as? [String: Any])
            let artifacts = try #require(object["artifacts"] as? [[String: Any]])
            #expect(artifacts.count == 1)
            #expect(artifacts.first?["targetName"] as? String == "Foo")
        }
    }

    @Test
    func restorePackageDownloadsAndAdvertisesRemoteBinaryArtifacts() async throws {
        try await withTemporaryDirectory { root in
            let package = root.appendingPathComponent("Package")
            let scratch = root.appendingPathComponent("scratch")
            let cache = try await Cache(root: root.appendingPathComponent("cache"))
            let pin = ResolvedPin(
                identity: "example.binary",
                kind: "registry",
                location: "",
                state: ResolvedState(branch: nil, revision: nil, version: "1.0.0")
            )
            let artifactURL = "https://example.com/Foo.zip"

            let zipPath = try await makeXCFrameworkZip(root: root, targetName: "Foo")
            let checksum = try Hashing.sha256Hex(await AsyncFileSystem.readData(from: zipPath))
            let archivePath = cache.binaryArtifactArchivePath(url: artifactURL, checksum: checksum)
            try await AsyncFileSystem.createDirectory(
                at: archivePath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await AsyncFileSystem.writeData(
                await AsyncFileSystem.readData(from: zipPath),
                to: archivePath
            )

            try await writeCachedManifest(
                binaryTargetManifest(name: "Foo", url: artifactURL, checksum: checksum),
                packageDir: cache.sourcePath(pin: pin)
            )
            try await writeCachedManifest(emptyManifest(), packageDir: package)

            let resolved = ResolvedPins(originHash: "origin", pins: [pin], version: 3)
            try await WorkspaceRestorer.restorePackage(
                scratchDir: scratch,
                cache: cache,
                registryConfig: RegistryConfig(),
                resolved: resolved,
                quiet: true
            )
            try await WorkspaceRestorer.writeWorkspaceState(
                packageDir: package, scratchDir: scratch, resolved: resolved, disableSandbox: false
            )

            let statePath = scratch.appendingPathComponent("workspace-state.json")
            let state = try #require(
                try JSONSerialization.jsonObject(
                    with: await AsyncFileSystem.readData(from: statePath))
                    as? [String: Any])
            let object = try #require(state["object"] as? [String: Any])
            let artifacts = try #require(object["artifacts"] as? [[String: Any]])
            let artifact = try #require(artifacts.first)

            #expect(artifacts.count == 1)
            #expect(artifact["targetName"] as? String == "Foo")
            #expect(try await AsyncFileSystem.exists(scratch.appendingPathComponent("artifacts/example.binary/Foo.xcframework")))
        }
    }

    private func makeXCFrameworkZip(root: URL, targetName: String) async throws -> URL {
        let archiveRoot = root.appendingPathComponent("archive")
        let framework = archiveRoot.appendingPathComponent("\(targetName).xcframework")
        try await AsyncFileSystem.createDirectory(at: framework, withIntermediateDirectories: true)
        try await AsyncFileSystem.atomicWrite(
            "<plist version=\"1.0\"></plist>",
            to: framework.appendingPathComponent("Info.plist")
        )
        let zipPath = root.appendingPathComponent("\(targetName).zip")
        try await SystemProcess.run(
            "/usr/bin/zip",
            ["-qry", zipPath.path, "\(targetName).xcframework"],
            workingDirectory: archiveRoot
        )
        return zipPath
    }

    private func binaryTargetManifest(name: String, url: String, checksum: String) -> [String: Any] {
        [
            "name": "BinaryPackage",
            "dependencies": [],
            "products": [],
            "targets": [
                [
                    "name": name,
                    "type": "binary",
                    "url": url,
                    "checksum": checksum,
                    "dependencies": [],
                    "exclude": [],
                    "resources": [],
                    "settings": [],
                ],
            ],
        ]
    }
}
