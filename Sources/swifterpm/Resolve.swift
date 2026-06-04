import Foundation

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
                location: canonicalSourceControlLocation(dependency.location)
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

func resolvePackage(
    packageDir: URL,
    cache: Cache,
    registryConfig: RegistryConfig,
    disableSandbox: Bool
) async throws -> ResolvedPins {
    let manifest = try dumpPackage(packageDir: packageDir, disableSandbox: disableSandbox)
    let dependencies = try parseManifestDependencies(manifest)
    let originHash = try originHash(packageDir: packageDir)
    guard !dependencies.isEmpty else {
        return ResolvedPins(originHash: originHash, pins: [], version: 3)
    }

    var fixedPins: [ResolvedPin] = []
    var rootDependencies: [(PackageKey, VersionRange)] = []
    var rootDirectPackages = Set<PackageKey>()

    for dependency in dependencies {
        if let range = versionRange(for: dependency.requirement) {
            let package = PackageKey.fromDependency(dependency)
            rootDirectPackages.insert(package)
            rootDependencies.append((package, range))
        } else {
            fixedPins.append(try resolveUnversionedDependency(dependency))
        }
    }

    let provider = NativeDependencyProvider(
        cache: cache,
        registryConfig: registryConfig,
        disableSandbox: disableSandbox,
        rootDirectPackages: rootDirectPackages
    )
    var pins = try await provider.solve(rootDependencies: rootDependencies)
    pins.append(contentsOf: fixedPins)
    pins = dedupePinsByIdentity(pins)
    pins.sort { $0.identity < $1.identity }

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

    private var versions: [PackageKey: [ResolvedVersion]] = [:]
    private var dependencies: [String: [(PackageKey, VersionRange)]] = [:]
    private var fixedPins: [String: ResolvedPin] = [:]

    init(cache: Cache, registryConfig: RegistryConfig, disableSandbox: Bool, rootDirectPackages: Set<PackageKey>) {
        self.cache = cache
        self.registryConfig = registryConfig
        self.disableSandbox = disableSandbox
        self.rootDirectPackages = rootDirectPackages
        versions[.root] = [ResolvedVersion(version: SemVer(major: 0, minor: 0, patch: 0), revision: nil)]
    }

    func solve(rootDependencies: [(PackageKey, VersionRange)]) async throws -> [ResolvedPin] {
        var constraints: [PackageKey: [VersionRange]] = [:]
        var selected: [PackageKey: ResolvedVersion] = [:]
        var queue: [PackageKey] = []

        for (package, range) in rootDependencies {
            constraints[package, default: []].append(range)
            queue.append(package)
        }

        var iterations = 0
        while !queue.isEmpty {
            iterations += 1
            if iterations > 10_000 {
                throw fail("dependency resolution exceeded iteration limit")
            }

            let package = queue.removeFirst()
            let ranges = constraints[package, default: []]
            let available = try await resolvedVersions(package)
            let matching = available.reversed().filter { version in
                ranges.allSatisfy { $0.contains(version.version) }
            }
            guard let chosen = matching.first(where: { $0.version.prerelease.isEmpty }) ?? matching.first else {
                throw fail("no versions found for \(package) matching constraints")
            }

            if selected[package]?.version == chosen.version {
                continue
            }
            selected[package] = chosen

            let transitives = try await dependenciesFor(package: package, version: chosen.version)
            for (dependency, range) in transitives {
                let existing = constraints[dependency, default: []]
                if !existing.contains(range) {
                    constraints[dependency] = existing + [range]
                    queue.append(dependency)
                }
            }
        }

        var pins: [ResolvedPin] = []
        for (package, resolvedVersion) in selected where package != .root {
            pins.append(try await pinForVersion(package: package, version: resolvedVersion.version))
        }
        pins.append(contentsOf: fixedPins.values)
        return pins
    }

    private func resolvedVersions(_ package: PackageKey) async throws -> [ResolvedVersion] {
        if let cached = versions[package] {
            return cached
        }

        var resolved: [ResolvedVersion]
        switch package.kind {
        case .root:
            resolved = []
        case .sourceControl:
            let remote = try await remoteVersions(location: package.location, cache: cache)
            resolved = remote.compactMap { remoteVersion in
                guard let semver = remoteVersion.semver else { return nil }
                return ResolvedVersion(version: semver, revision: remoteVersion.revision)
            }
        case .registry:
            let registry = try await registryVersions(identity: package.identity, registryConfig: registryConfig, cache: cache)
            resolved = registry.compactMap { registryVersion in
                guard let semver = registryVersion.semver else { return nil }
                return ResolvedVersion(version: semver, revision: nil)
            }
        }
        resolved.sort { $0.version < $1.version }
        versions[package] = resolved
        return resolved
    }

    private func dependenciesFor(package: PackageKey, version: SemVer) async throws -> [(PackageKey, VersionRange)] {
        let cacheKey = "\(package.identity)|\(package.kind)|\(package.location)|\(version)"
        if let cached = dependencies[cacheKey] {
            return cached
        }

        let source = try await manifestSource(package: package, version: version)
        let manifest = try dumpPackage(packageDir: source, disableSandbox: disableSandbox)
        let manifestDependencies = rootDirectPackages.contains(package)
            ? try parseManifestDependencies(manifest)
            : try parseRequiredManifestDependencies(manifest)

        var result: [(PackageKey, VersionRange)] = []
        for dependency in manifestDependencies {
            if let range = versionRange(for: dependency.requirement) {
                result.append((PackageKey.fromDependency(dependency), range))
            } else {
                let pin = try resolveUnversionedDependency(dependency)
                fixedPins[pin.identity.lowercased()] = pin
            }
        }

        dependencies[cacheKey] = result
        return result
    }

    private func materialize(package: PackageKey, version: SemVer) async throws -> URL {
        let pin = try await pinForVersion(package: package, version: version)
        switch package.kind {
        case .root:
            throw fail("root package cannot be materialized")
        case .sourceControl:
            return try await ensureSource(cache: cache, pin: pin)
        case .registry:
            return try await ensureRegistrySource(cache: cache, registryConfig: registryConfig, pin: pin)
        }
    }

    private func manifestSource(package: PackageKey, version: SemVer) async throws -> URL {
        if package.kind == .sourceControl,
           let local = localSourceControlPackageLocation(package.location)
        {
            return local
        }
        return try await materialize(package: package, version: version)
    }

    private func pinForVersion(package: PackageKey, version: SemVer) async throws -> ResolvedPin {
        switch package.kind {
        case .root:
            throw fail("root package has no pin")
        case .sourceControl:
            let versions = try await resolvedVersions(package)
            guard let resolvedVersion = versions.first(where: { $0.version == version }),
                  let revision = resolvedVersion.revision
            else {
                throw fail("version \(version) was not found for \(package.identity)")
            }
            return ResolvedPin(
                identity: package.identity,
                kind: sourceControlKind(location: package.location),
                location: package.location,
                state: ResolvedState(branch: nil, revision: revision, version: version.description)
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
}

private func resolveUnversionedDependency(_ dependency: ManifestDependency) throws -> ResolvedPin {
    if dependency.kind == .registry {
        throw fail("registry dependencies do not support branch or revision requirements")
    }

    let state: ResolvedState
    switch dependency.requirement {
    case let .revision(revision):
        state = ResolvedState(branch: nil, revision: revision, version: nil)
    case let .branch(branch):
        state = ResolvedState(
            branch: branch,
            revision: try resolveNamedRef(location: dependency.location, name: branch),
            version: nil
        )
    case .exact, .range:
        throw fail("internal error: versioned requirement reached unversioned resolver")
    }

    return ResolvedPin(
        identity: dependency.identity,
        kind: sourceControlKind(location: dependency.location),
        location: dependency.location,
        state: state
    )
}

private func dedupePinsByIdentity(_ pins: [ResolvedPin]) -> [ResolvedPin] {
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

private func canonicalSourceControlLocation(_ location: String) -> String {
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

func localSourceControlPackageLocation(_ location: String) -> URL? {
    let url: URL
    if let fileURL = URL(string: location), fileURL.isFileURL {
        url = fileURL
    } else if location.hasPrefix("/") {
        url = URL(fileURLWithPath: location)
    } else {
        return nil
    }

    guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) else {
        return nil
    }
    return url.standardizedFileURL.resolvingSymlinksInPath()
}

func sourceControlKind(location: String) -> String {
    localSourceControlPackageLocation(location) == nil ? "remoteSourceControl" : "localSourceControl"
}

private func originHash(packageDir: URL) throws -> String {
    sha256Hex(try Data(contentsOf: packageDir.appendingPathComponent("Package.swift")))
}
