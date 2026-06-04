import Foundation

enum PackageResolver {
    private struct PackageKey: Hashable, CustomStringConvertible, Sendable {
        enum Kind: Hashable, Sendable {
            case root
            case sourceControl
            case registry
        }

        let identity: String
        let kind: Kind
        let location: String

        static let root = PackageKey(identity: "__root__", kind: .root, location: "")

        static func fromDependency(_ dependency: ManifestDependency) -> PackageKey {
            switch dependency.kind {
            case .sourceControl:
                return PackageKey(
                    identity: dependency.identity,
                    kind: .sourceControl,
                    location: PackageResolver.canonicalSourceControlLocation(dependency.location)
                )
            case .registry:
                return PackageKey(
                    identity: dependency.identity,
                    kind: .registry,
                    location: dependency.location
                )
            }
        }

        var description: String { identity }
    }

    private struct ResolvedVersion: Sendable {
        let version: SemVer
        let revision: String?
    }

    static func resolve(
        packageDir: URL,
        cache: Cache,
        registryConfig: RegistryConfig,
        disableSandbox: Bool,
        progress: ResolutionProgressReporter? = nil
    ) async throws -> ResolvedPins {
        let manifest = try await ManifestLoader.dumpPackage(
            packageDir: packageDir, disableSandbox: disableSandbox)
        let dependencies = try ManifestParser.dependencies(manifest)
        let originHash = try await originHash(packageDir: packageDir)
        guard !dependencies.isEmpty else {
            return ResolvedPins(originHash: originHash, pins: [], version: 3)
        }

        var fixedPins: [ResolvedPin] = []
        var rootDependencies: [(PackageKey, VersionRange)] = []
        var rootDirectPackages = Set<PackageKey>()
        progress?.started(
            rootVersionedDependencies: dependencies.filter {
                ManifestParser.versionRange(for: $0.requirement) != nil
            }.count,
            fixedDependencies: dependencies.filter {
                ManifestParser.versionRange(for: $0.requirement) == nil
            }.count
        )

        for dependency in dependencies {
            if let range = ManifestParser.versionRange(for: dependency.requirement) {
                let package = PackageKey.fromDependency(dependency)
                rootDirectPackages.insert(package)
                rootDependencies.append((package, range))
            } else {
                progress?.startedResolvingFixedPin(package: dependency.identity)
                let pin = try await resolveUnversionedDependency(dependency)
                progress?.finishedResolvingFixedPin(package: dependency.identity)
                fixedPins.append(pin)
            }
        }

        let provider = NativeDependencyProvider(
            cache: cache,
            registryConfig: registryConfig,
            disableSandbox: disableSandbox,
            rootDirectPackages: rootDirectPackages,
            progress: progress
        )
        var pins = try await provider.solve(rootDependencies: rootDependencies)
        pins.append(contentsOf: fixedPins)
        pins = dedupePinsByIdentity(pins)
        pins.sort { $0.identity < $1.identity }
        progress?.finished(pinCount: pins.count)

        return ResolvedPins(
            originHash: originHash,
            pins: pins,
            version: 3
        )
    }

    private final class NativeDependencyProvider {
        let cache: Cache
        let registryConfig: RegistryConfig
        let disableSandbox: Bool
        let rootDirectPackages: Set<PackageKey>
        let progress: ResolutionProgressReporter?

        private var versions: [PackageKey: [ResolvedVersion]] = [:]
        private var dependencies: [String: [(PackageKey, VersionRange)]] = [:]
        private var fixedPins: [String: ResolvedPin] = [:]

        init(
            cache: Cache, registryConfig: RegistryConfig, disableSandbox: Bool,
            rootDirectPackages: Set<PackageKey>,
            progress: ResolutionProgressReporter?
        ) {
            self.cache = cache
            self.registryConfig = registryConfig
            self.disableSandbox = disableSandbox
            self.rootDirectPackages = rootDirectPackages
            self.progress = progress
            versions[.root] = [
                ResolvedVersion(version: SemVer(major: 0, minor: 0, patch: 0), revision: nil)
            ]
        }

        func solve(rootDependencies: [(PackageKey, VersionRange)]) async throws -> [ResolvedPin] {
            var constraints: [PackageKey: [VersionRange]] = [:]
            var selected: [PackageKey: ResolvedVersion] = [:]
            var queue: [PackageKey] = []

            for (package, range) in rootDependencies {
                constraints[package, default: []].append(range)
                queue.append(package)
            }
            try await prefetchVersions(rootDependencies.map(\.0))

            var iterations = 0
            while !queue.isEmpty {
                iterations += 1
                if iterations > 10_000 {
                    throw ToolError.message("dependency resolution exceeded iteration limit")
                }

                let package = queue.removeFirst()
                let ranges = constraints[package, default: []]
                let available = try await resolvedVersions(package)
                let matching = available.reversed().filter { version in
                    ranges.allSatisfy { $0.contains(version.version) }
                }
                guard
                    let chosen = matching.first(where: { $0.version.prerelease.isEmpty })
                        ?? matching.first
                else {
                    throw ToolError.message("no versions found for \(package) matching constraints")
                }

                if selected[package]?.version == chosen.version {
                    continue
                }
                selected[package] = chosen
                progress?.selected(package: package.identity, version: chosen.version.description)

                let transitives = try await dependenciesFor(
                    package: package, version: chosen.version)
                var discoveredPackages: [PackageKey] = []
                for (dependency, range) in transitives {
                    let existing = constraints[dependency, default: []]
                    if !existing.contains(range) {
                        constraints[dependency] = existing + [range]
                        queue.append(dependency)
                        discoveredPackages.append(dependency)
                    }
                }
                try await prefetchVersions(discoveredPackages)
            }

            var pins: [ResolvedPin] = []
            for (package, resolvedVersion) in selected where package != .root {
                pins.append(
                    try await pinForResolvedVersion(
                        package: package, resolvedVersion: resolvedVersion))
            }
            pins.append(contentsOf: fixedPins.values)
            return pins
        }

        private func prefetchVersions(_ packages: [PackageKey]) async throws {
            let missing = Array(Set(packages)).filter { versions[$0] == nil }
            if missing.isEmpty {
                return
            }

            let fetched = try await withThrowingTaskGroup(of: (PackageKey, [ResolvedVersion]).self)
            {
                group in
                for package in missing {
                    let cache = cache
                    let registryConfig = registryConfig
                    let progress = progress
                    group.addTask {
                        progress?.startedFetchingVersions(package: package.identity)
                        let versions = try await Self.fetchResolvedVersions(
                            package: package,
                            cache: cache,
                            registryConfig: registryConfig
                        )
                        progress?.finishedFetchingVersions(
                            package: package.identity,
                            versionCount: versions.count
                        )
                        return (package, versions)
                    }
                }

                var result: [(PackageKey, [ResolvedVersion])] = []
                for try await item in group {
                    result.append(item)
                }
                return result
            }

            for (package, resolved) in fetched where versions[package] == nil {
                versions[package] = resolved
            }
        }

        private func resolvedVersions(_ package: PackageKey) async throws -> [ResolvedVersion] {
            if let cached = versions[package] {
                return cached
            }

            let resolved = try await Self.fetchResolvedVersions(
                package: package,
                cache: cache,
                registryConfig: registryConfig
            )
            versions[package] = resolved
            return resolved
        }

        private static func fetchResolvedVersions(
            package: PackageKey,
            cache: Cache,
            registryConfig: RegistryConfig
        ) async throws -> [ResolvedVersion] {
            var resolved: [ResolvedVersion]
            switch package.kind {
            case .root:
                resolved = []
            case .sourceControl:
                let remote = try await RemoteMetadata.versions(
                    location: package.location, cache: cache)
                resolved = remote.compactMap { remoteVersion in
                    guard let semver = remoteVersion.semver else { return nil }
                    return ResolvedVersion(version: semver, revision: remoteVersion.revision)
                }
            case .registry:
                let registry = try await RegistryClient.versions(
                    identity: package.identity, registryConfig: registryConfig, cache: cache)
                resolved = registry.compactMap { registryVersion in
                    guard let semver = registryVersion.semver else { return nil }
                    return ResolvedVersion(version: semver, revision: nil)
                }
            }
            resolved.sort { $0.version < $1.version }
            return resolved
        }

        private func dependenciesFor(package: PackageKey, version: SemVer) async throws -> [(
            PackageKey, VersionRange
        )] {
            let cacheKey = "\(package.identity)|\(package.kind)|\(package.location)|\(version)"
            if let cached = dependencies[cacheKey] {
                return cached
            }

            progress?.startedInspectingManifest(
                package: package.identity, version: version.description)
            let source = try await manifestSource(package: package, version: version)
            let manifest = try await ManifestLoader.dumpPackage(
                packageDir: source, disableSandbox: disableSandbox)
            let manifestDependencies =
                rootDirectPackages.contains(package)
                ? try ManifestParser.dependencies(manifest)
                : try ManifestParser.requiredDependencies(manifest)

            var result: [(PackageKey, VersionRange)] = []
            for dependency in manifestDependencies {
                if let range = ManifestParser.versionRange(for: dependency.requirement) {
                    result.append((PackageKey.fromDependency(dependency), range))
                } else {
                    progress?.startedResolvingFixedPin(package: dependency.identity)
                    let pin = try await PackageResolver.resolveUnversionedDependency(dependency)
                    progress?.finishedResolvingFixedPin(package: dependency.identity)
                    fixedPins[pin.identity.lowercased()] = pin
                }
            }

            dependencies[cacheKey] = result
            progress?.finishedInspectingManifest(
                package: package.identity,
                version: version.description,
                dependencyCount: result.count
            )
            return result
        }

        private func materialize(package: PackageKey, version: SemVer) async throws -> URL {
            let pin = try await pinForVersion(package: package, version: version)
            switch package.kind {
            case .root:
                throw ToolError.message("root package cannot be materialized")
            case .sourceControl:
                return try await WorkspaceRestorer.ensureSource(cache: cache, pin: pin)
            case .registry:
                return try await WorkspaceRestorer.ensureRegistrySource(
                    cache: cache, registryConfig: registryConfig, pin: pin)
            }
        }

        private func manifestSource(package: PackageKey, version: SemVer) async throws -> URL {
            if package.kind == .sourceControl,
                let local = try await PackageResolver.localSourceControlPackageLocation(
                    package.location)
            {
                return local
            }
            return try await materialize(package: package, version: version)
        }

        private func pinForVersion(package: PackageKey, version: SemVer) async throws -> ResolvedPin
        {
            switch package.kind {
            case .root:
                throw ToolError.message("root package has no pin")
            case .sourceControl:
                let versions = try await resolvedVersions(package)
                guard let resolvedVersion = versions.first(where: { $0.version == version }),
                    let revision = resolvedVersion.revision
                else {
                    throw ToolError.message(
                        "version \(version) was not found for \(package.identity)")
                }
                return ResolvedPin(
                    identity: package.identity,
                    kind: try await PackageResolver.sourceControlKind(location: package.location),
                    location: package.location,
                    state: ResolvedState(
                        branch: nil, revision: revision, version: version.description)
                )
            case .registry:
                return ResolvedPin(
                    identity: package.identity,
                    kind: "registry",
                    location: "",
                    state: ResolvedState(branch: nil, revision: nil, version: version.description)
                )
            }
        }

        private func pinForResolvedVersion(package: PackageKey, resolvedVersion: ResolvedVersion)
            async throws -> ResolvedPin
        {
            switch package.kind {
            case .root:
                throw ToolError.message("root package has no pin")
            case .sourceControl:
                guard let revision = resolvedVersion.revision else {
                    throw ToolError.message(
                        "version \(resolvedVersion.version) was not found for \(package.identity)")
                }
                return ResolvedPin(
                    identity: package.identity,
                    kind: try await PackageResolver.sourceControlKind(location: package.location),
                    location: package.location,
                    state: ResolvedState(
                        branch: nil, revision: revision,
                        version: resolvedVersion.version.description)
                )
            case .registry:
                return ResolvedPin(
                    identity: package.identity,
                    kind: "registry",
                    location: "",
                    state: ResolvedState(
                        branch: nil, revision: nil, version: resolvedVersion.version.description)
                )
            }
        }
    }

    private static func resolveUnversionedDependency(_ dependency: ManifestDependency) async throws
        -> ResolvedPin
    {
        if dependency.kind == .registry {
            throw ToolError.message(
                "registry dependencies do not support branch or revision requirements")
        }

        let state: ResolvedState
        switch dependency.requirement {
        case .revision(let revision):
            state = ResolvedState(branch: nil, revision: revision, version: nil)
        case .branch(let branch):
            state = ResolvedState(
                branch: branch,
                revision: try await RemoteMetadata.resolveNamedRef(
                    location: dependency.location, name: branch),
                version: nil
            )
        case .exact, .range:
            throw ToolError.message(
                "internal error: versioned requirement reached unversioned resolver")
        }

        return ResolvedPin(
            identity: dependency.identity,
            kind: try await PackageResolver.sourceControlKind(location: dependency.location),
            location: dependency.location,
            state: state
        )
    }

    private static func dedupePinsByIdentity(_ pins: [ResolvedPin]) -> [ResolvedPin] {
        var order: [String] = []
        var chosen: [String: ResolvedPin] = [:]
        for pin in pins {
            let key = pin.identity.lowercased()
            if let existing = chosen[key] {
                if existing.state.version == nil && pin.state.version != nil {
                    chosen[key] = pin
                }
            } else {
                order.append(key)
                chosen[key] = pin
            }
        }
        return order.compactMap { chosen[$0] }
    }

    private static func canonicalSourceControlLocation(_ location: String) -> String {
        var value = location
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.hasSuffix(".git") {
            value = String(value.dropLast(4))
        }
        if let repo = try? GitHubRepo(location: value) {
            return "https://github.com/\(repo.owner.lowercased())/\(repo.repo.lowercased())"
        }
        return value
    }

    static func localSourceControlPackageLocation(_ location: String) async throws -> URL? {
        let url: URL
        if let fileURL = URL(string: location), fileURL.isFileURL {
            url = fileURL
        } else if location.hasPrefix("/") {
            url = URL(fileURLWithPath: location)
        } else {
            return nil
        }

        guard try await AsyncFileSystem.exists(url.appendingPathComponent("Package.swift")) else {
            return nil
        }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func sourceControlKind(location: String) async throws -> String {
        let local = try await localSourceControlPackageLocation(location)
        return local == nil ? "remoteSourceControl" : "localSourceControl"
    }

    private static func originHash(packageDir: URL) async throws -> String {
        Hashing.sha256Hex(
            try await AsyncFileSystem.readData(
                from: packageDir.appendingPathComponent("Package.swift")))
    }
}
