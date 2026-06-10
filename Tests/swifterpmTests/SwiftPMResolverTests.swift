import Basics
import Foundation
import PackageGraph
import PackageModel
import Testing

@testable import SwifterPMCore

struct SwiftPMResolverTests {
    // Tuist and `swift package dump-package` lowercase package identities, but
    // the location must flow into Package.resolved exactly as declared in the
    // manifest. An older resolver rewrote locations to a canonical
    // https://lowercase form without the .git suffix, which made swifterpm's
    // Package.resolved permanently diverge from SwiftPM's for anyone switching
    // between the tools. These tests pin the verbatim behavior.
    @Test(arguments: [
        "https://github.com/openid/AppAuth-iOS.git",
        "https://github.com/openid/appauth-ios",
        "git@github.com:riversidefm/Riverside-Mobile-Shared.git",
        "ssh://git@github.com/riversidefm/Riverside-Mobile-Shared.git",
        "https://github.com/jpsim/Yams/",
    ])
    func packageReferencePreservesDeclaredLocation(location: String) throws {
        let dependency = ManifestDependency(
            identity: "dependency",
            kind: .sourceControl,
            location: location,
            requirement: .range(
                lower: SemVer(major: 1, minor: 0, patch: 0),
                upper: SemVer(major: 2, minor: 0, patch: 0)
            )
        )

        let reference = try SwiftPMResolverBridge.swiftPMPackageReference(for: dependency)

        #expect(reference.identity == PackageIdentity.plain("dependency"))
        #expect(reference.kind == .remoteSourceControl(SourceControlURL(location)))
        #expect(reference.locationString == location)
    }

    @Test
    func packageReferenceKeepsLocationCaseWhenIdentityIsLowercase() throws {
        // dump-package lowercases the identity; the location must stay as declared.
        let dependency = ManifestDependency(
            identity: "riverside-mobile-ffmpeg-kit",
            kind: .sourceControl,
            location: "git@github.com:riversidefm/Riverside-Mobile-ffmpeg-kit.git",
            requirement: .exact(SemVer(major: 1, minor: 0, patch: 14))
        )

        let reference = try SwiftPMResolverBridge.swiftPMPackageReference(for: dependency)

        #expect(reference.locationString == "git@github.com:riversidefm/Riverside-Mobile-ffmpeg-kit.git")
    }

    @Test
    func storedPackageReferencePreservesPinLocation() throws {
        let pin = ResolvedPin(
            identity: "riverside-mobile-shared",
            kind: "remoteSourceControl",
            location: "git@github.com:riversidefm/Riverside-Mobile-Shared.git",
            state: ResolvedState(
                branch: nil,
                revision: "bfb610f26a2f9c3d601ade3071c1ae5bd68da48d",
                version: "1.7.4"
            )
        )

        let reference = try SwiftPMResolverBridge.storedPackageReference(for: pin)

        #expect(reference.identity == PackageIdentity.plain("riverside-mobile-shared"))
        #expect(reference.locationString == "git@github.com:riversidefm/Riverside-Mobile-Shared.git")
    }

    @Test
    func storedResolutionStateMapsVersionBranchAndRevisionPins() throws {
        let versionPin = ResolvedState(branch: nil, revision: "abc123", version: "1.7.4")
        let branchPin = ResolvedState(branch: "shutdown-patch", revision: "def456", version: nil)
        let revisionPin = ResolvedState(branch: nil, revision: "0123abc", version: nil)
        let emptyPin = ResolvedState(branch: nil, revision: nil, version: nil)

        #expect(
            SwiftPMResolverBridge.storedResolutionState(for: pin(state: versionPin))
                == .version(try SwiftPMVersion(versionString: "1.7.4"), revision: "abc123"))
        #expect(
            SwiftPMResolverBridge.storedResolutionState(for: pin(state: branchPin))
                == .branch(name: "shutdown-patch", revision: "def456"))
        #expect(SwiftPMResolverBridge.storedResolutionState(for: pin(state: revisionPin)) == .revision("0123abc"))
        #expect(SwiftPMResolverBridge.storedResolutionState(for: pin(state: emptyPin)) == nil)
    }

    @Test
    func resolvedPackagesStoreSeedsPinsByIdentity() throws {
        let pins = [
            ResolvedPin(
                identity: "swift-log",
                kind: "remoteSourceControl",
                location: "https://github.com/Apple/Swift-Log.git",
                state: ResolvedState(branch: nil, revision: "abc123", version: "1.12.0")
            ),
            ResolvedPin(
                identity: "soto-core",
                kind: "remoteSourceControl",
                location: "https://github.com/riversidefm/soto-core.git",
                state: ResolvedState(branch: "shutdown-patch", revision: "def456", version: nil)
            ),
            // Unusable pins are skipped instead of failing the whole seed.
            ResolvedPin(
                identity: "broken",
                kind: "remoteSourceControl",
                location: "https://github.com/example/broken",
                state: ResolvedState(branch: nil, revision: nil, version: nil)
            ),
        ]

        let store = SwiftPMResolverBridge.resolvedPackagesStore(pins)

        #expect(store.count == 2)
        let swiftLog = try #require(store[PackageIdentity.plain("swift-log")])
        #expect(swiftLog.packageRef.locationString == "https://github.com/Apple/Swift-Log.git")
        #expect(
            swiftLog.state
                == .version(try SwiftPMVersion(versionString: "1.12.0"), revision: "abc123"))
        let sotoCore = try #require(store[PackageIdentity.plain("soto-core")])
        #expect(sotoCore.state == .branch(name: "shutdown-patch", revision: "def456"))
    }

    @Test
    func resolvedPackagesStoreDedupesPinsDifferingOnlyByIdentityCase() throws {
        // `PackageIdentity.plain` lowercases, so these two collide on one store
        // key. The seed must keep one deterministically (preferring the
        // versioned pin) rather than whichever happens to be iterated last,
        // otherwise the dropped identity gets re-resolved freely.
        let pins = [
            ResolvedPin(
                identity: "Swift-Log",
                kind: "remoteSourceControl",
                location: "https://github.com/apple/swift-log.git",
                state: ResolvedState(branch: nil, revision: nil, version: nil)
            ),
            ResolvedPin(
                identity: "swift-log",
                kind: "remoteSourceControl",
                location: "https://github.com/apple/swift-log.git",
                state: ResolvedState(branch: nil, revision: "abc123", version: "1.12.0")
            ),
        ]

        let store = SwiftPMResolverBridge.resolvedPackagesStore(pins)

        #expect(store.count == 1)
        let pin = try #require(store[PackageIdentity.plain("swift-log")])
        // The versioned pin wins over the revision-less one regardless of order.
        #expect(
            pin.state == .version(try SwiftPMVersion(versionString: "1.12.0"), revision: "abc123"))
    }

    @Test
    func resolvedPackagesStoreMapsRegistryAndLocalPins() async throws {
        try await withTemporaryDirectory { root in
            let pins = [
                ResolvedPin(
                    identity: "apple.swift-log",
                    kind: "registry",
                    location: "apple.swift-log",
                    state: ResolvedState(branch: nil, revision: nil, version: "1.12.0")
                ),
                ResolvedPin(
                    identity: "local-package",
                    kind: "localSourceControl",
                    location: root.path,
                    state: ResolvedState(branch: nil, revision: "abc123", version: "1.0.0")
                ),
            ]

            let store = SwiftPMResolverBridge.resolvedPackagesStore(pins)

            let registry = try #require(store[PackageIdentity.plain("apple.swift-log")])
            guard case .registry = registry.packageRef.kind else {
                Issue.record("expected registry, got \(registry.packageRef.kind)")
                return
            }
            let local = try #require(store[PackageIdentity.plain("local-package")])
            guard case .localSourceControl(let path) = local.packageRef.kind else {
                Issue.record("expected localSourceControl, got \(local.packageRef.kind)")
                return
            }
            #expect(path.pathString == root.path)
        }
    }

    private func pin(state: ResolvedState) -> ResolvedPin {
        ResolvedPin(
            identity: "dependency",
            kind: "remoteSourceControl",
            location: "https://github.com/example/dependency.git",
            state: state
        )
    }
}
