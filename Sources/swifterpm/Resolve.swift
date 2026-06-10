import Foundation

enum PackageResolver {
    static func resolve(
        packageDir: URL,
        cache: Cache,
        registryConfig: RegistryConfig,
        disableSandbox: Bool,
        scmToRegistryTransformation: SCMToRegistryTransformation = .disabled,
        existingPins: [ResolvedPin] = [],
        progress: ResolutionProgressReporter? = nil
    ) async throws -> ResolvedPins {
        let manifest = try await ManifestLoader.dumpPackage(
            packageDir: packageDir, disableSandbox: disableSandbox)
        var manifestDependencies = try ManifestParser.dependencies(manifest)
        let localPackages = try await ManifestFileSystemDependencyGraph.collect(
            rootPackageDir: packageDir,
            rootManifest: manifest,
            disableSandbox: disableSandbox
        )
        for localPackage in localPackages {
            manifestDependencies.append(contentsOf: try ManifestParser.dependencies(localPackage.manifest))
        }
        let dependencies = try await transformedDependencies(
            manifestDependencies,
            registryConfig: registryConfig,
            scmToRegistryTransformation: scmToRegistryTransformation
        )
        let originHash = try await originHash(packageDir: packageDir)
        guard !dependencies.isEmpty else {
            return ResolvedPins(originHash: originHash, pins: [], version: 3)
        }

        progress?.started(
            rootVersionedDependencies: dependencies.filter {
                ManifestParser.versionRange(for: $0.requirement) != nil
            }.count,
            fixedDependencies: dependencies.filter {
                ManifestParser.versionRange(for: $0.requirement) == nil
            }.count
        )

        var pins = try await SwiftPMResolverBridge.resolve(
            dependencies: dependencies,
            existingPins: existingPins,
            cache: cache,
            registryConfig: registryConfig,
            disableSandbox: disableSandbox,
            scmToRegistryTransformation: scmToRegistryTransformation,
            progress: progress
        )
        pins = dedupePinsByIdentity(pins)
        pins.sort { $0.identity < $1.identity }
        progress?.finished(pinCount: pins.count)

        return ResolvedPins(
            originHash: originHash,
            pins: pins,
            version: 3
        )
    }

    static func transformedDependencies(
        _ dependencies: [ManifestDependency],
        registryConfig: RegistryConfig,
        scmToRegistryTransformation: SCMToRegistryTransformation,
        registryIdentityLookup: @Sendable @escaping (String, RegistryConfig) async throws
            -> [String] = { sourceControlURL, registryConfig in
                try await RegistryClient.identifiers(
                    sourceControlURL: sourceControlURL,
                    registryConfig: registryConfig
                )
            }
    ) async throws -> [ManifestDependency] {
        guard scmToRegistryTransformation != .disabled else {
            return dependencies
        }

        return try await ConcurrentTasks.map(dependencies) { dependency in
            guard dependency.kind == .sourceControl,
                  ManifestParser.versionRange(for: dependency.requirement) != nil
            else {
                return dependency
            }

            let identifiers = try await registryIdentityLookup(dependency.location, registryConfig)
            guard let registryIdentity = identifiers.sorted().first else {
                return dependency
            }

            switch scmToRegistryTransformation {
            case .disabled:
                return dependency
            case .useRegistryIdentityForSCM:
                return ManifestDependency(
                    identity: registryIdentity,
                    kind: .sourceControl,
                    location: dependency.location,
                    requirement: dependency.requirement
                )
            case .replaceSCMWithRegistry:
                return ManifestDependency(
                    identity: registryIdentity,
                    kind: .registry,
                    location: dependency.location,
                    requirement: dependency.requirement
                )
            }
        }
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

    static func localSourceControlPackageLocation(_ location: String) async throws -> URL? {
        let url: URL
        if let fileURL = URL(string: location), fileURL.isFileURL {
            url = fileURL
        } else if location.hasPrefix("/") {
            url = URL(fileURLWithPath: location)
        } else {
            return nil
        }

        guard try await fileSystem.exists(url.appendingPathComponent("Package.swift").absolutePath) else {
            return nil
        }
        return url.standardizedFileURL
    }

    static func sourceControlKind(location: String) async throws -> String {
        let local = try await localSourceControlPackageLocation(location)
        return local == nil ? "remoteSourceControl" : "localSourceControl"
    }

    private static func originHash(packageDir: URL) async throws -> String {
        Hashing.sha256Hex(
            try await fileSystem.readFile(
                at: packageDir.appendingPathComponent("Package.swift").absolutePath))
    }
}
