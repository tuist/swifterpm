import Foundation
import Testing

struct CLIRunnerTests {
    @Test
    func resolvePreservesCurrentPackageResolved() async throws {
        try await withTemporaryDirectory { root in
            try await writeMinimalPackageManifest(at: root, name: "Fixture")
            let resolved = try await currentResolvedPins(packageDir: root)
            try await ResolvedFile.write(packageDir: root, resolved: resolved)

            try await CLIRunner.run(
                CLI(
                    cachePath: root.appendingPathComponent("cache"),
                    disableSandbox: true,
                    quiet: true,
                    command: .resolve(.init(packageDir: root))
                ))

            #expect(try await ResolvedFile.read(packageDir: root).pins == resolved.pins)
        }
    }

    @Test
    func updateRefreshesCurrentPackageResolved() async throws {
        try await withTemporaryDirectory { root in
            try await writeMinimalPackageManifest(at: root, name: "Fixture")
            try await ResolvedFile.write(
                packageDir: root,
                resolved: await currentResolvedPins(packageDir: root)
            )

            try await CLIRunner.run(
                CLI(
                    cachePath: root.appendingPathComponent("cache"),
                    disableSandbox: true,
                    quiet: true,
                    command: .update(.init(packageDir: root))
                ))

            #expect(try await ResolvedFile.read(packageDir: root).pins.isEmpty)
        }
    }

    private func currentResolvedPins(packageDir: URL) async throws -> ResolvedPins {
        try ResolvedPins(
            originHash: await ResolvedFile.packageOriginHash(packageDir: packageDir),
            pins: [
                ResolvedPin(
                    identity: "preserved",
                    kind: "unsupported",
                    location: "",
                    state: ResolvedState(branch: nil, revision: "abcdef123456", version: nil)
                ),
            ],
            version: 3
        )
    }
}
