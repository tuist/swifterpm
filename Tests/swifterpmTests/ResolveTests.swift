import Foundation
import Testing

struct ResolveTests {
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
    func localSourceControlPackageLocationAcceptsFileURLs() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try "package manifest\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        #expect(localSourceControlPackageLocation(root.absoluteString)?.path == root.path)
    }
}
