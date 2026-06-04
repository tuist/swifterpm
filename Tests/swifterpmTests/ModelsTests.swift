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
        #expect(checkoutDirectoryName(pin) == "foo")
        #expect(isSourceControlKind(pin.kind))
        #expect(!isRegistryKind(pin.kind))

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
        #expect(isRegistryKind(pin.kind))
        #expect(try registryDownloadSubpath(pin) == "example/package/1.2.3")
        #expect(throws: (any Error).self) {
            try registryIdentityParts("unscoped")
        }
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
}
