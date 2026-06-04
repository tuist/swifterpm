import Foundation
import Testing

struct ModelsTests {
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
        #expect(PinKind.checkoutDirectoryName(pin) == "foo")
        #expect(PinKind.isSourceControl(pin.kind))
        #expect(!PinKind.isRegistry(pin.kind))

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
        let (scope, name) = try PinKind.registryIdentityParts("example.package")
        #expect(scope == "example")
        #expect(name == "package")

        let pin = ResolvedPin(
            identity: "example.package",
            kind: "registry",
            location: "",
            state: ResolvedState(branch: nil, revision: nil, version: "1.2.3")
        )
        #expect(PinKind.isRegistry(pin.kind))
        #expect(try PinKind.registryDownloadSubpath(pin) == "example/package/1.2.3")
        #expect(throws: (any Error).self) {
            try PinKind.registryIdentityParts("unscoped")
        }
    }

    @Test
    func readAndWriteResolvedFileRoundTripsInsidePackageDirectory() async throws {
        try await withTemporaryDirectory { root in
            let resolved = ResolvedPins(
                originHash: "origin",
                pins: [
                    ResolvedPin(
                        identity: "foo",
                        kind: "remoteSourceControl",
                        location: "https://github.com/example/foo",
                        state: ResolvedState(
                            branch: nil, revision: "abcdef123456", version: "1.0.0")
                    )
                ],
                version: 3
            )

            try await ResolvedFile.write(packageDir: root, resolved: resolved)
            #expect(try await ResolvedFile.read(packageDir: root).pins == resolved.pins)
            #expect(try await ResolvedFile.read(packageDir: root).originHash == "origin")
        }
    }

    @Test
    func downloadedMixedRegistryAndGitHubResolvedFixtureDecodes() async throws {
        let fixture = try await fixtureURL("MixedRegistryAndGitHub")
        let resolved = try await ResolvedFile.read(packageDir: fixture)
        let packageManifest = String(
            data: try await AsyncFileSystem.readData(
                from: fixture.appendingPathComponent("Package.swift")),
            encoding: .utf8
        )
        let identities = Set(resolved.pins.map(\.identity))

        #expect(resolved.version == 3)
        #expect(
            resolved.originHash
                == "4d417b634d3a503175acfb1710b87fdc09ada364bff47b2a716050126ff3a1e0")
        #expect(packageManifest?.contains(".package(id: \"marmelroy.PhoneNumberKit\"") == true)
        #expect(
            packageManifest?.contains("https://github.com/firebase/firebase-ios-sdk.git") == true)
        #expect(resolved.pins.count == 27)
        #expect(identities.contains("firebase-ios-sdk"))
        #expect(identities.contains("marmelroy.PhoneNumberKit"))
        #expect(resolved.pins.filter { PinKind.isRegistry($0.kind) }.count == 3)
        #expect(resolved.pins.filter { PinKind.isSourceControl($0.kind) }.count == 24)
    }
}
