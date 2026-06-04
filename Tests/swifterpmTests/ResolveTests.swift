import Foundation
import Testing

struct ResolveTests {
    @Test
    func localSourceControlPackageLocationRequiresPackageManifest() async throws {
        try await withTemporaryDirectory { root in
            #expect(try await localSourceControlPackageLocation(root.path) == nil)
            try await atomicWrite("package manifest\n", to: root.appendingPathComponent("Package.swift"))

            #expect(try await localSourceControlPackageLocation(root.path)?.path == root.path)
            #expect(try await sourceControlKind(location: root.path) == "localSourceControl")
            #expect(try await sourceControlKind(location: "https://github.com/example/foo") == "remoteSourceControl")
        }
    }

    @Test
    func localSourceControlPackageLocationAcceptsFileURLs() async throws {
        try await withTemporaryDirectory { root in
            try await atomicWrite("package manifest\n", to: root.appendingPathComponent("Package.swift"))

            #expect(try await localSourceControlPackageLocation(root.absoluteString)?.path == root.path)
        }
    }
}
