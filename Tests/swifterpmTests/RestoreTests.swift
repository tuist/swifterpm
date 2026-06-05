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
    func writeWorkspaceStateUsesSourceControlManifestNameAndCheckoutSubpath() async throws {
        try await withTemporaryDirectory { root in
            let package = root.appendingPathComponent("Package")
            let scratch = root.appendingPathComponent("scratch")
            let checkout = scratch.appendingPathComponent("checkouts/deck-of-playing-cards")
            try await writeCachedManifest(emptyManifest(), packageDir: package)
            try await writeCachedManifest(
                emptyManifest(name: "DeckOfPlayingCards"),
                packageDir: checkout
            )

            let resolved = ResolvedPins(
                originHash: "origin",
                pins: [
                    ResolvedPin(
                        identity: "deck-of-playing-cards",
                        kind: "localSourceControl",
                        location: root.appendingPathComponent("deck-of-playing-cards").path,
                        state: ResolvedState(
                            branch: nil,
                            revision: "abcdef1234567890",
                            version: "1.0.0"
                        )
                    ),
                ],
                version: 3
            )

            try await WorkspaceRestorer.writeWorkspaceState(
                packageDir: package,
                scratchDir: scratch,
                resolved: resolved,
                disableSandbox: false
            )

            let statePath = scratch.appendingPathComponent("workspace-state.json")
            let state = try #require(
                try JSONSerialization.jsonObject(
                    with: await AsyncFileSystem.readData(from: statePath))
                    as? [String: Any])
            let object = try #require(state["object"] as? [String: Any])
            let dependencies = try #require(object["dependencies"] as? [[String: Any]])
            let dependency = try #require(dependencies.first)
            let packageRef = try #require(dependency["packageRef"] as? [String: Any])

            #expect(packageRef["name"] as? String == "DeckOfPlayingCards")
            #expect(dependency["subpath"] as? String == "deck-of-playing-cards")
        }
    }

    @Test
    func writeWorkspaceStateWritesRootLocalBinaryArtifacts() async throws {
        try await withTemporaryDirectory { root in
            let package = root.appendingPathComponent("Package")
            let scratch = root.appendingPathComponent("scratch")
            let framework = package.appendingPathComponent("XCFrameworks/Foo.xcframework")
            try await AsyncFileSystem.createDirectory(
                at: framework,
                withIntermediateDirectories: true
            )
            try await AsyncFileSystem.atomicWrite(
                validXCFrameworkInfoPlist(),
                to: framework.appendingPathComponent("Info.plist")
            )
            try await writeCachedManifest(
                localBinaryTargetManifest(name: "Foo", path: "XCFrameworks/Foo.xcframework"),
                packageDir: package
            )

            let resolved = ResolvedPins(originHash: "origin", pins: [], version: 3)

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
            let packageRef = try #require(artifact["packageRef"] as? [String: Any])
            let source = try #require(artifact["source"] as? [String: Any])
            #expect(artifacts.count == 1)
            #expect(artifact["targetName"] as? String == "Foo")
            #expect(artifact["path"] as? String == PathCanonicalizer.realpath(framework).path)
            #expect(packageRef["kind"] as? String == "root")
            #expect(packageRef["identity"] as? String == "package")
            #expect(source["type"] as? String == "local")
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
                packageDir: package,
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
            let packageRef = try #require(artifact["packageRef"] as? [String: Any])
            let source = try #require(artifact["source"] as? [String: Any])
            let artifactPath = scratch
                .appendingPathComponent("artifacts/example.binary/Foo/Foo.xcframework")

            #expect(artifacts.count == 1)
            #expect(artifact["targetName"] as? String == "Foo")
            #expect(artifact["path"] as? String == artifactPath.path)
            #expect(packageRef["kind"] as? String == "registry")
            #expect(packageRef["location"] as? String == "example.binary")
            #expect(source["type"] as? String == "remote")
            #expect(source["url"] as? String == artifactURL)
            #expect(source["checksum"] as? String == checksum)
            #expect(try await AsyncFileSystem.exists(artifactPath))
        }
    }

    private func makeXCFrameworkZip(root: URL, targetName: String) async throws -> URL {
        let archiveRoot = root.appendingPathComponent("archive")
        let framework = archiveRoot.appendingPathComponent("\(targetName).xcframework")
        try await AsyncFileSystem.createDirectory(at: framework, withIntermediateDirectories: true)
        try await AsyncFileSystem.atomicWrite(
            validXCFrameworkInfoPlist(),
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

    private func validXCFrameworkInfoPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>AvailableLibraries</key>
          <array>
            <dict>
              <key>LibraryIdentifier</key>
              <string>macos-arm64</string>
              <key>LibraryPath</key>
              <string>Foo.framework</string>
              <key>SupportedArchitectures</key>
              <array>
                <string>arm64</string>
              </array>
              <key>SupportedPlatform</key>
              <string>macos</string>
            </dict>
          </array>
        </dict>
        </plist>
        """
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

    private func localBinaryTargetManifest(name: String, path: String) -> [String: Any] {
        [
            "name": "BinaryPackage",
            "dependencies": [],
            "products": [],
            "targets": [
                [
                    "name": name,
                    "type": "binary",
                    "path": path,
                    "dependencies": [],
                    "exclude": [],
                    "resources": [],
                    "settings": [],
                ],
            ],
        ]
    }
}
