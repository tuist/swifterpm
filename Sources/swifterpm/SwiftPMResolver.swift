import Basics
import Foundation
@preconcurrency import PackageGraph
import PackageModel
import TSCUtility

typealias SwiftPMVersion = TSCUtility.Version

final class SwiftPMDependencyProvider: PackageContainerProvider {
    private let cache: Cache
    private let registryConfig: RegistryConfig
    private let disableSandbox: Bool
    private let scmToRegistryTransformation: SCMToRegistryTransformation
    private let progress: ResolutionProgressReporter?
    private let branchRequirements = BranchRequirements()
    private let registryFallbackLocations = RegistryFallbackLocations()

    private let containersLock = NSLock()
    private var containers: [String: SwiftPMPackageContainer] = [:]

    fileprivate init(
        cache: Cache,
        registryConfig: RegistryConfig,
        disableSandbox: Bool,
        scmToRegistryTransformation: SCMToRegistryTransformation,
        progress: ResolutionProgressReporter?
    ) {
        self.cache = cache
        self.registryConfig = registryConfig
        self.disableSandbox = disableSandbox
        self.scmToRegistryTransformation = scmToRegistryTransformation
        self.progress = progress
    }

    func getContainer(
        for package: PackageReference,
        updateStrategy: ContainerUpdateStrategy,
        observabilityScope: ObservabilityScope
    ) async throws -> PackageContainer {
        let key = containerKey(for: package)
        if let container = containersLock.withLock({ containers[key] }) {
            return container
        }
        let container = SwiftPMPackageContainer(
            package: package,
            cache: cache,
            registryConfig: registryConfig,
            disableSandbox: disableSandbox,
            scmToRegistryTransformation: scmToRegistryTransformation,
            branchRequirements: branchRequirements,
            registryFallbackLocations: registryFallbackLocations,
            progress: progress
        )
        return containersLock.withLock {
            if let existing = containers[key] {
                return existing
            }
            containers[key] = container
            return container
        }
    }

    func registerBranchRequirement(package: PackageReference, branch: String) {
        branchRequirements.register(package: package, branch: branch)
    }

    func branchRequirement(for package: PackageReference) -> String? {
        branchRequirements.branch(for: package)
    }

    func registerRegistryFallbackLocation(package: PackageReference, location: String) {
        registryFallbackLocations.register(package: package, location: location)
    }

    private func containerKey(for package: PackageReference) -> String {
        "\(package.kind)|\(package.identity.description.lowercased())|\(package.locationString)"
    }
}

final class SwiftPMPackageContainer: PackageContainer {
    let package: PackageReference

    private let cache: Cache
    private let registryConfig: RegistryConfig
    private let disableSandbox: Bool
    private let scmToRegistryTransformation: SCMToRegistryTransformation
    private let branchRequirements: BranchRequirements
    private let registryFallbackLocations: RegistryFallbackLocations
    private let progress: ResolutionProgressReporter?

    private let cacheLock = NSLock()
    private var resolvedVersions: [ResolvedVersion]?
    private var dependencyInfo: [String: DependencyInfo] = [:]

    fileprivate init(
        package: PackageReference,
        cache: Cache,
        registryConfig: RegistryConfig,
        disableSandbox: Bool,
        scmToRegistryTransformation: SCMToRegistryTransformation,
        branchRequirements: BranchRequirements,
        registryFallbackLocations: RegistryFallbackLocations,
        progress: ResolutionProgressReporter?
    ) {
        self.package = package
        self.cache = cache
        self.registryConfig = registryConfig
        self.disableSandbox = disableSandbox
        self.scmToRegistryTransformation = scmToRegistryTransformation
        self.branchRequirements = branchRequirements
        self.registryFallbackLocations = registryFallbackLocations
        self.progress = progress
    }

    func isToolsVersionCompatible(at version: SwiftPMVersion) async -> Bool {
        true
    }

    func toolsVersion(for version: SwiftPMVersion) async throws -> ToolsVersion {
        .current
    }

    func toolsVersionsAppropriateVersionsDescending() async throws -> [SwiftPMVersion] {
        try await versionsDescending()
    }

    func versionsAscending() async throws -> [SwiftPMVersion] {
        try await versions().map(\.version)
    }

    func versionsDescending() async throws -> [SwiftPMVersion] {
        try await versions().map(\.version).reversed()
    }

    func getDependencies(
        at version: SwiftPMVersion,
        productFilter: ProductFilter,
        _ enabledTraits: EnabledTraits
    ) async throws -> [PackageContainerConstraint] {
        try await info(version: version).constraints
    }

    func getDependencies(
        at revision: String,
        productFilter: ProductFilter,
        _ enabledTraits: EnabledTraits
    ) async throws -> [PackageContainerConstraint] {
        try await revisionInfo(revision: revision).constraints
    }

    func getUnversionedDependencies(
        productFilter: ProductFilter,
        _ enabledTraits: EnabledTraits
    ) async throws -> [PackageContainerConstraint] {
        []
    }

    func loadPackageReference(at boundVersion: BoundVersion) async throws -> PackageReference {
        package
    }

    func resolvedPin(for version: SwiftPMVersion) async throws -> ResolvedPin {
        let resolvedVersion = try await versions().first { $0.version == version }
        guard let resolvedVersion else {
            throw ToolError.message("version \(version) was not found for \(package.identity)")
        }

        switch package.kind {
        case .registry:
            if let revision = resolvedVersion.revision {
                let location = registryFallbackLocation ?? package.locationString
                return ResolvedPin(
                    identity: package.identity.description,
                    kind: try await PackageResolver.sourceControlKind(location: location),
                    location: location,
                    state: ResolvedState(
                        branch: nil,
                        revision: revision,
                        version: version.description
                    )
                )
            }
            return ResolvedPin(
                identity: package.identity.description,
                kind: "registry",
                location: "",
                state: ResolvedState(branch: nil, revision: nil, version: version.description)
            )
        default:
            guard let revision = resolvedVersion.revision else {
                throw ToolError.message("version \(version) was not found for \(package.identity)")
            }
            return ResolvedPin(
                identity: package.identity.description,
                kind: try await PackageResolver.sourceControlKind(location: package.locationString),
                location: package.locationString,
                state: ResolvedState(branch: nil, revision: revision, version: version.description)
            )
        }
    }

    func resolvedPin(for boundVersion: BoundVersion, branch: String?) async throws -> ResolvedPin? {
        switch boundVersion {
        case .excluded, .unversioned:
            return nil
        case .version(let version):
            return try await resolvedPin(for: version)
        case .revision(let revision, let resolvedBranch):
            let branchName = branch ?? resolvedBranch
            let resolvedRevision = if let branchName {
                try await RemoteMetadata.resolveNamedRef(
                    location: registryFallbackLocation ?? package.locationString,
                    name: branchName
                )
            } else {
                revision
            }
            let location = registryFallbackLocation ?? package.locationString
            return ResolvedPin(
                identity: package.identity.description,
                kind: try await PackageResolver.sourceControlKind(location: location),
                location: location,
                state: ResolvedState(
                    branch: branchName,
                    revision: resolvedRevision,
                    version: nil
                )
            )
        }
    }

    private func versions() async throws -> [ResolvedVersion] {
        if let resolvedVersions = cacheLock.withLock({ resolvedVersions }) {
            return resolvedVersions
        }

        progress?.startedFetchingVersions(package: package.identity.description)
        let resolved = try await fetchResolvedVersions()
        progress?.finishedFetchingVersions(
            package: package.identity.description,
            versionCount: resolved.count
        )
        return cacheLock.withLock {
            if let existing = resolvedVersions {
                return existing
            }
            resolvedVersions = resolved
            return resolved
        }
    }

    private func fetchResolvedVersions() async throws -> [ResolvedVersion] {
        var resolved: [ResolvedVersion]
        switch package.kind {
        case .root, .fileSystem:
            resolved = []
        case .remoteSourceControl, .localSourceControl:
            let remote = try await RemoteMetadata.versions(
                location: package.locationString,
                cache: cache
            )
            resolved = remote.compactMap { remoteVersion in
                guard let version = try? SwiftPMVersion(versionString: remoteVersion.version) else {
                    return nil
                }
                return ResolvedVersion(version: version, revision: remoteVersion.revision)
            }
        case .registry:
            let registry = try await RegistryClient.versions(
                identity: package.identity.description,
                registryConfig: registryConfig,
                cache: cache
            )
            resolved = registry.compactMap { registryVersion in
                guard let version = try? SwiftPMVersion(versionString: registryVersion.version) else {
                    return nil
                }
                return ResolvedVersion(version: version, revision: nil)
            }
            if let fallbackLocation = registryFallbackLocation, resolved.isEmpty,
               canFallBackToSourceControl(fallbackLocation)
            {
                let remote = try await RemoteMetadata.versions(
                    location: fallbackLocation,
                    cache: cache
                )
                resolved = remote.compactMap { remoteVersion in
                    guard let version = try? SwiftPMVersion(versionString: remoteVersion.version) else {
                        return nil
                    }
                    return ResolvedVersion(version: version, revision: remoteVersion.revision)
                }
            }
        }
        return resolved.sorted { $0.version < $1.version }
    }

    private func info(version: SwiftPMVersion) async throws -> DependencyInfo {
        let key = version.description
        if let cached = cacheLock.withLock({ dependencyInfo[key] }) {
            return cached
        }

        progress?.startedInspectingManifest(
            package: package.identity.description,
            version: version.description
        )
        let source = try await manifestSource(version: version)
        return try await loadInfo(
            cacheKey: key,
            source: source,
            versionDescription: version.description
        )
    }

    private func revisionInfo(revision: String) async throws -> DependencyInfo {
        let key = "revision|\(revision)"
        if let cached = cacheLock.withLock({ dependencyInfo[key] }) {
            return cached
        }

        let source = try await manifestSource(revision: revision)
        return try await loadInfo(
            cacheKey: key,
            source: source,
            versionDescription: revision
        )
    }

    private func loadInfo(
        cacheKey: String,
        source: Foundation.URL,
        versionDescription: String
    ) async throws -> DependencyInfo {
        if let cached = cacheLock.withLock({ dependencyInfo[cacheKey] }) {
            return cached
        }

        progress?.startedInspectingManifest(
            package: package.identity.description,
            version: versionDescription
        )
        let manifest = try await ManifestLoader.dumpPackage(
            packageDir: source,
            disableSandbox: disableSandbox
        )
        let rawDependencies = try ManifestParser.requiredDependencies(manifest)
        let dependencies = try await PackageResolver.transformedDependencies(
            rawDependencies,
            registryConfig: registryConfig,
            scmToRegistryTransformation: scmToRegistryTransformation
        )

        var constraints: [PackageContainerConstraint] = []
        for dependency in dependencies {
            let packageReference = try SwiftPMResolverBridge.swiftPMPackageReference(for: dependency)
            if dependency.kind == .registry, dependency.location != dependency.identity {
                registryFallbackLocations.register(
                    package: packageReference,
                    location: dependency.location
                )
            }
            if case .branch(let branch) = dependency.requirement {
                branchRequirements.register(package: packageReference, branch: branch)
            }
            constraints.append(
                PackageContainerConstraint(
                    package: packageReference,
                    requirement: try swiftPMPackageRequirement(for: dependency.requirement),
                    products: .everything
                )
            )
        }

        let info = DependencyInfo(constraints: constraints)
        cacheLock.withLock {
            dependencyInfo[cacheKey] = info
        }
        progress?.finishedInspectingManifest(
            package: package.identity.description,
            version: versionDescription,
            dependencyCount: constraints.count
        )
        return info
    }

    private func manifestSource(version: SwiftPMVersion) async throws -> Foundation.URL {
        if case .localSourceControl = package.kind,
           let local = try await PackageResolver.localSourceControlPackageLocation(package.locationString)
        {
            return local
        }
        let pin = try await resolvedPin(for: version)
        switch package.kind {
        case .registry where PinKind.isRegistry(pin.kind):
            return try await WorkspaceRestorer.ensureRegistrySource(
                cache: cache,
                registryConfig: registryConfig,
                pin: pin
            )
        default:
            return try await WorkspaceRestorer.ensureSource(cache: cache, pin: pin)
        }
    }

    private func manifestSource(revision: String) async throws -> Foundation.URL {
        if case .localSourceControl = package.kind,
           let local = try await PackageResolver.localSourceControlPackageLocation(package.locationString)
        {
            return local
        }
        let pin = ResolvedPin(
            identity: package.identity.description,
            kind: try await PackageResolver.sourceControlKind(location: package.locationString),
            location: package.locationString,
            state: ResolvedState(branch: nil, revision: revision, version: nil)
        )
        return try await WorkspaceRestorer.ensureSource(cache: cache, pin: pin)
    }

    private func canFallBackToSourceControl(_ location: String) -> Bool {
        location.hasPrefix("/") || Foundation.URL(string: location)?.scheme != nil
    }

    private var registryFallbackLocation: String? {
        registryFallbackLocations.location(for: package)
    }
}

private struct ResolvedVersion: Sendable {
    let version: SwiftPMVersion
    let revision: String?
}

private struct DependencyInfo {
    let constraints: [PackageContainerConstraint]
}

private final class BranchRequirements: @unchecked Sendable {
    private let lock = NSLock()
    private var branches: [String: String] = [:]

    func register(package: PackageReference, branch: String) {
        lock.withLock {
            branches[Self.key(for: package)] = branch
        }
    }

    func branch(for package: PackageReference) -> String? {
        lock.withLock {
            branches[Self.key(for: package)]
        }
    }

    private static func key(for package: PackageReference) -> String {
        "\(package.kind)|\(package.identity.description.lowercased())|\(package.locationString)"
    }
}

private final class RegistryFallbackLocations: @unchecked Sendable {
    private let lock = NSLock()
    private var locations: [String: String] = [:]

    func register(package: PackageReference, location: String) {
        lock.withLock {
            locations[Self.key(for: package)] = location
        }
    }

    func location(for package: PackageReference) -> String? {
        lock.withLock {
            locations[Self.key(for: package)]
        }
    }

    private static func key(for package: PackageReference) -> String {
        "\(package.kind)|\(package.identity.description.lowercased())|\(package.locationString)"
    }
}

enum SwiftPMResolverBridge {
    static func resolve(
        dependencies: [ManifestDependency],
        existingPins: [ResolvedPin] = [],
        cache: Cache,
        registryConfig: RegistryConfig,
        disableSandbox: Bool,
        scmToRegistryTransformation: SCMToRegistryTransformation,
        progress: ResolutionProgressReporter?
    ) async throws -> [ResolvedPin] {
        let provider = SwiftPMDependencyProvider(
            cache: cache,
            registryConfig: registryConfig,
            disableSandbox: disableSandbox,
            scmToRegistryTransformation: scmToRegistryTransformation,
            progress: progress
        )

        var constraints: [PackageContainerConstraint] = []
        for dependency in dependencies {
            let packageReference = try SwiftPMResolverBridge.swiftPMPackageReference(for: dependency)
            if dependency.kind == .registry, dependency.location != dependency.identity {
                provider.registerRegistryFallbackLocation(
                    package: packageReference,
                    location: dependency.location
                )
            }
            if case .branch(let branch) = dependency.requirement {
                provider.registerBranchRequirement(package: packageReference, branch: branch)
            }
            constraints.append(
                PackageContainerConstraint(
                    package: packageReference,
                    requirement: try swiftPMPackageRequirement(for: dependency.requirement),
                    products: .everything
                )
            )
        }

        let resolver = PubGrubDependencyResolver(
            provider: provider,
            resolvedPackages: resolvedPackagesStore(existingPins),
            skipDependenciesUpdates: true,
            prefetchBasedOnResolvedFile: false,
            observabilityScope: ObservabilitySystem.NOOP
        )
        let result = await resolver.solve(constraints: constraints)
        let bindings = try result.get()

        var pins: [ResolvedPin] = []
        for binding in bindings {
            let container = try await provider.getContainer(
                for: binding.package,
                updateStrategy: .never,
                observabilityScope: ObservabilitySystem.NOOP
            ) as? SwiftPMPackageContainer
            guard let container else { continue }
            if let pin = try await container.resolvedPin(
                for: binding.boundVersion,
                branch: provider.branchRequirement(for: binding.package)
            ) {
                pins.append(pin)
            }
        }
        return pins
    }

    static func resolvedPackagesStore(_ pins: [ResolvedPin]) -> ResolvedPackagesStore
        .ResolvedPackages
    {
        var store: ResolvedPackagesStore.ResolvedPackages = [:]
        // `PackageIdentity.plain` lowercases, so pins differing only by case
        // collide on the same store key. Dedupe first (preferring versioned
        // pins) so seeding is deterministic instead of last-iteration-wins.
        for pin in PackageResolver.dedupePinsByIdentity(pins) {
            guard let reference = try? storedPackageReference(for: pin),
                  let state = storedResolutionState(for: pin)
            else { continue }
            store[reference.identity] = ResolvedPackagesStore.ResolvedPackage(
                packageRef: reference,
                state: state,
                originalScmUrl: nil
            )
        }
        return store
    }

    static func storedPackageReference(for pin: ResolvedPin) throws -> PackageReference {
        try packageReference(
            identity: pin.identity,
            location: pin.location,
            isRegistry: PinKind.isRegistry(pin.kind)
        )
    }

    static func swiftPMPackageReference(for dependency: ManifestDependency) throws
        -> PackageReference
    {
        try packageReference(
            identity: dependency.identity,
            location: dependency.location,
            isRegistry: dependency.kind == .registry
        )
    }

    /// Build a SwiftPM `PackageReference` from a raw identity and location,
    /// shared by the pin (resolved) and dependency (manifest) paths so the two
    /// cannot drift on how a location maps to local / remote / registry.
    private static func packageReference(
        identity: String,
        location: String,
        isRegistry: Bool
    ) throws -> PackageReference {
        let id = PackageIdentity.plain(identity)
        if isRegistry {
            return .registry(identity: id)
        }
        if location.hasPrefix("/") {
            return try .localSourceControl(identity: id, path: AbsolutePath(validating: location))
        }
        if let url = Foundation.URL(string: location), url.isFileURL {
            return try .localSourceControl(identity: id, path: AbsolutePath(validating: url.path))
        }
        return .remoteSourceControl(identity: id, url: SourceControlURL(location))
    }

    static func storedResolutionState(for pin: ResolvedPin) -> ResolvedPackagesStore
        .ResolutionState?
    {
        if let branch = pin.state.branch, let revision = pin.state.revision {
            return .branch(name: branch, revision: revision)
        }
        if let version = pin.state.version,
           let parsed = try? SwiftPMVersion(versionString: version)
        {
            return .version(parsed, revision: pin.state.revision)
        }
        if let revision = pin.state.revision {
            return .revision(revision)
        }
        return nil
    }
}

private func swiftPMPackageRequirement(for requirement: Requirement) throws -> PackageRequirement {
    switch requirement {
    case .exact(let version):
        return try .versionSet(.exact(swiftPMVersion(version)))
    case .range(let lower, let upper):
        return try .versionSet(.range(swiftPMVersion(lower)..<swiftPMVersion(upper)))
    case .branch(let branch):
        return .revision(branch)
    case .revision(let revision):
        return .revision(revision)
    }
}

private func swiftPMVersion(_ version: SemVer) throws -> SwiftPMVersion {
    try SwiftPMVersion(versionString: version.description)
}
