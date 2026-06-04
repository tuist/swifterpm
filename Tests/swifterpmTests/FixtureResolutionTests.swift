import Foundation
import Testing

private let packageFixturePaths = [
    "ExternalDependencies",
    "MixedRegistryAndGitHub",
    "SanitizedTuistPackages/Caly-main",
    "SanitizedTuistPackages/Fasting",
    "SanitizedTuistPackages/ProteinTracker",
]

struct FixtureResolutionTests {
    @Test(arguments: packageFixturePaths)
    func recordedResolutionCoversManifestDependencies(fixturePath: String) async throws {
        try await withTemporaryDirectory { root in
            let source = try await fixtureURL(fixturePath.split(separator: "/").map(String.init))
            let package = root.appendingPathComponent(source.lastPathComponent)
            try await SystemProcess.run("/bin/cp", ["-R", source.path, package.path])

            let manifest = try await ManifestLoader.dumpPackage(
                packageDir: package, disableSandbox: true)
            let dependencies = try ManifestParser.dependencies(manifest)
            let resolved = try await ResolvedFile.read(packageDir: package)
            let pinsByIdentity = Dictionary(
                uniqueKeysWithValues: resolved.pins.map { ($0.identity.lowercased(), $0) })

            #expect(!dependencies.isEmpty)
            #expect(!resolved.pins.isEmpty)

            for dependency in dependencies {
                let pin = pinsByIdentity[dependency.identity.lowercased()]
                #expect(pin != nil)
                guard let pin else { continue }

                switch dependency.requirement {
                case .exact(let version):
                    #expect(pin.state.version == version.description)
                case .revision(let revision):
                    #expect(pin.state.revision == revision)
                case .branch(let branch):
                    #expect(pin.state.branch == branch)
                case .range:
                    break
                }
            }
        }
    }
}
