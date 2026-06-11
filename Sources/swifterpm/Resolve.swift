import Foundation

enum PackageResolver {
    static func resolve(
        packageDir: URL,
        scratchDir: URL? = nil,
        cache: Cache,
        registryConfig: RegistryConfig,
        registryConfigurationPath: URL? = nil,
        defaultRegistryURL: String? = nil,
        disableSandbox: Bool,
        scmToRegistryTransformation: SCMToRegistryTransformation = .disabled,
        writeResolvedFile: Bool = true,
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
        let dependencies = manifestDependencies
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

        let resolutionInput = try await swiftPMResolutionInput(
            packageDir: packageDir,
            cache: cache,
            registryConfig: registryConfig,
            dependencies: dependencies,
            scmToRegistryTransformation: scmToRegistryTransformation
        )
        do {
            var resolved = try await resolveWithSwiftPackageManagerProcess(
                packageDir: resolutionInput.packageDir,
                scratchDir: scratchDir,
                cacheDir: cache.root,
                registryConfigurationPath: registryConfigurationPath,
                defaultRegistryURL: defaultRegistryURL,
                disableSandbox: disableSandbox,
                scmToRegistryTransformation: resolutionInput.swiftPMTransformation,
                writeResolvedFile: writeResolvedFile
            )
            resolved.originHash = originHash
            resolved.pins = applyRegistryIdentityOverrides(
                resolved.pins,
                pinOverrides: resolutionInput.pinOverrides
            )
            if writeResolvedFile {
                try await ResolvedFile.write(packageDir: packageDir, resolved: resolved)
            }
            if let cleanupDirectory = resolutionInput.cleanupDirectory {
                try? await fileSystem.removePath(cleanupDirectory)
            }
            progress?.finished(pinCount: resolved.pins.count)
            return resolved
        } catch {
            if let cleanupDirectory = resolutionInput.cleanupDirectory {
                try? await fileSystem.removePath(cleanupDirectory)
            }
            throw error
        }
    }

    private struct SwiftPMResolutionInput {
        let packageDir: URL
        let cleanupDirectory: URL?
        let pinOverrides: [String: PinOverride]
        let swiftPMTransformation: SCMToRegistryTransformation
    }

    private static func swiftPMResolutionInput(
        packageDir: URL,
        cache: Cache,
        registryConfig: RegistryConfig,
        dependencies: [ManifestDependency],
        scmToRegistryTransformation: SCMToRegistryTransformation
    ) async throws -> SwiftPMResolutionInput {
        guard scmToRegistryTransformation != .disabled else {
            return SwiftPMResolutionInput(
                packageDir: packageDir,
                cleanupDirectory: nil,
                pinOverrides: [:],
                swiftPMTransformation: .disabled
            )
        }

        let workspace = try await fileSystem.temporaryDirectory(
            in: cache.root.appendingPathComponent("resolver-packages")
        )
        let prepared = try await registryPreparedDependencies(
            dependencies,
            packageDir: packageDir,
            workspace: workspace,
            cache: cache,
            registryConfig: registryConfig,
            scmToRegistryTransformation: scmToRegistryTransformation
        )
        let resolverPackage = try await writeResolverPackage(
            dependencies: prepared.dependencies,
            workspace: workspace
        )
        return SwiftPMResolutionInput(
            packageDir: resolverPackage,
            cleanupDirectory: workspace,
            pinOverrides: prepared.pinOverrides,
            swiftPMTransformation: .disabled
        )
    }

    private struct RegistryPreparedDependencies {
        let dependencies: [ManifestDependency]
        let pinOverrides: [String: PinOverride]
    }

    private enum PinOverride {
        case registry(identity: String)
        case sourceControlIdentity(String)
    }

    private static func registryPreparedDependencies(
        _ dependencies: [ManifestDependency],
        packageDir: URL,
        workspace: URL,
        cache: Cache,
        registryConfig: RegistryConfig,
        scmToRegistryTransformation: SCMToRegistryTransformation
    ) async throws -> RegistryPreparedDependencies {
        var prepared: [ManifestDependency] = []
        var pinOverrides: [String: PinOverride] = [:]

        for dependency in dependencies {
            guard dependency.kind == .sourceControl,
                  let versionRange = ManifestParser.versionRange(for: dependency.requirement)
            else {
                prepared.append(dependency)
                continue
            }

            let identifiers = try await RegistryClient.identifiers(
                sourceControlURL: dependency.location,
                registryConfig: registryConfig
            )
            guard let registryIdentity = identifiers.sorted().first else {
                prepared.append(dependency)
                continue
            }

            let sourceControlDependency = ManifestDependency(
                identity: registryIdentity,
                kind: .sourceControl,
                location: dependency.location,
                requirement: dependency.requirement,
                nameForTargetDependencyResolutionOnly:
                    dependency.nameForTargetDependencyResolutionOnly
            )
            switch scmToRegistryTransformation {
            case .disabled:
                prepared.append(dependency)
            case .useRegistryIdentityForSCM:
                prepared.append(sourceControlDependency)
                addPinOverride(
                    .sourceControlIdentity(registryIdentity),
                    for: dependency.location,
                    packageDir: packageDir,
                    to: &pinOverrides
                )
            case .replaceSCMWithRegistry:
                let versions = try await RegistryClient.versions(
                    identity: registryIdentity,
                    registryConfig: registryConfig,
                    cache: cache
                )
                let compatibleRegistryVersions = versions.filter { version in
                    guard let semver = version.semver else { return false }
                    return versionRange.contains(semver)
                }
                if compatibleRegistryVersions.isEmpty {
                    prepared.append(sourceControlDependency)
                    addPinOverride(
                        .sourceControlIdentity(registryIdentity),
                        for: dependency.location,
                        packageDir: packageDir,
                        to: &pinOverrides
                    )
                } else {
                    let registryRepository = try await writeRegistryRepository(
                        identity: registryIdentity,
                        versions: compatibleRegistryVersions,
                        requirement: dependency.requirement,
                        workspace: workspace,
                        cache: cache,
                        registryConfig: registryConfig
                    )
                    prepared.append(registryRepository)
                    addPinOverride(
                        .registry(identity: registryIdentity),
                        for: registryRepository.location,
                        packageDir: packageDir,
                        to: &pinOverrides
                    )
                }
            }
        }

        return RegistryPreparedDependencies(
            dependencies: prepared,
            pinOverrides: pinOverrides
        )
    }

    private static func addPinOverride(
        _ override: PinOverride,
        for location: String,
        packageDir: URL,
        to overrides: inout [String: PinOverride]
    ) {
        for alias in sourceControlLocationAliases(location, packageDir: packageDir) {
            overrides[alias] = override
        }
    }

    private static func sourceControlLocationAliases(_ location: String, packageDir: URL) -> [String] {
        var aliases = [location]
        var withoutTrailingSlash = location
        while withoutTrailingSlash.hasSuffix("/") {
            withoutTrailingSlash.removeLast()
        }
        if withoutTrailingSlash != location {
            aliases.append(withoutTrailingSlash)
        }
        if withoutTrailingSlash.hasSuffix(".git") {
            aliases.append(String(withoutTrailingSlash.dropLast(4)))
        }
        if location.hasPrefix("/") {
            aliases.append(URL(fileURLWithPath: location).standardizedFileURL.path)
        } else if let url = URL(string: location), url.isFileURL {
            aliases.append(url.standardizedFileURL.path)
        } else if URL(string: location)?.scheme == nil {
            aliases.append(
                packageDir.appendingPathComponent(location).standardizedFileURL.path
            )
        }
        return Array(Set(aliases))
    }

    private static func applyRegistryIdentityOverrides(
        _ pins: [ResolvedPin],
        pinOverrides: [String: PinOverride]
    ) -> [ResolvedPin] {
        pins.map { pin in
            guard PinKind.isSourceControl(pin.kind),
                  let override = pinOverride(for: pin, pinOverrides: pinOverrides)
            else {
                return pin
            }
            switch override {
            case .registry(let identity):
                return ResolvedPin(
                    identity: identity,
                    kind: "registry",
                    location: "",
                    state: ResolvedState(branch: nil, revision: nil, version: pin.state.version)
                )
            case .sourceControlIdentity(let identity):
                return ResolvedPin(
                    identity: identity,
                    kind: pin.kind,
                    location: pin.location,
                    state: pin.state
                )
            }
        }
    }

    private static func pinOverride(
        for pin: ResolvedPin,
        pinOverrides: [String: PinOverride]
    ) -> PinOverride? {
        sourceControlLocationAliases(pin.location, packageDir: URL(fileURLWithPath: "/"))
            .lazy
            .compactMap { pinOverrides[$0] }
            .first
    }

    private static func writeRegistryRepository(
        identity: String,
        versions: [RegistryVersion],
        requirement: Requirement,
        workspace: URL,
        cache: Cache,
        registryConfig: RegistryConfig
    ) async throws -> ManifestDependency {
        let repository = workspace
            .appendingPathComponent("registry-repositories")
            .appendingPathComponent(SafePathComponent.make(identity))
        try await fileSystem.makeDirectory(
            at: repository.absolutePath,
            options: [.createTargetParentDirectories]
        )
        try await SystemProcess.run("git", ["init"], workingDirectory: repository)
        try await SystemProcess.run(
            "git", ["config", "user.name", "SwifterPM"], workingDirectory: repository)
        try await SystemProcess.run(
            "git", ["config", "user.email", "swifterpm@tuist.dev"], workingDirectory: repository)

        for version in versions {
            let pin = ResolvedPin(
                identity: identity,
                kind: "registry",
                location: "",
                state: ResolvedState(branch: nil, revision: nil, version: version.version)
            )
            let source = try await WorkspaceRestorer.ensureRegistrySource(
                cache: cache,
                registryConfig: registryConfig,
                pin: pin
            )
            try await replaceRepositoryContents(repository: repository, source: source)
            try await SystemProcess.run("git", ["add", "-A"], workingDirectory: repository)
            try await SystemProcess.run(
                "git",
                ["commit", "--allow-empty", "-m", "\(identity) \(version.version)"],
                workingDirectory: repository
            )
            try await SystemProcess.run("git", ["tag", version.version], workingDirectory: repository)
        }

        return ManifestDependency(
            identity: identity,
            kind: .sourceControl,
            location: repository.path,
            requirement: requirement
        )
    }

    private static func replaceRepositoryContents(repository: URL, source: URL) async throws {
        for entry in try await fileSystem.contentsOfDirectory(at: repository)
            where entry.lastPathComponent != ".git"
        {
            try await fileSystem.removePath(entry)
        }
        for entry in try await fileSystem.contentsOfDirectory(at: source) {
            try await fileSystem.copy(
                entry.absolutePath,
                to: repository.appendingPathComponent(entry.lastPathComponent).absolutePath
            )
        }
    }

    private static func writeResolverPackage(
        dependencies: [ManifestDependency],
        workspace: URL
    ) async throws -> URL {
        let packageDir = workspace.appendingPathComponent("package")
        try await fileSystem.makeDirectory(
            at: packageDir.absolutePath,
            options: [.createTargetParentDirectories]
        )
        let dependencyLines = try dependencies.map { dependency in
            try "        \(manifestDependency(dependency)),"
        }.joined(separator: "\n")
        try await fileSystem.atomicWrite(
            """
            // swift-tools-version:6.0
            import PackageDescription

            let package = Package(
                name: "SwifterPMResolutionRoot",
                dependencies: [
            \(dependencyLines)
                ]
            )
            """,
            to: packageDir.appendingPathComponent("Package.swift")
        )
        return packageDir
    }

    private static func manifestDependency(_ dependency: ManifestDependency) throws -> String {
        let requirement = try manifestRequirement(dependency.requirement)
        switch dependency.kind {
        case .registry:
            return ".package(id: \(swiftStringLiteral(dependency.identity)), \(requirement))"
        case .sourceControl:
            return ".package(url: \(swiftStringLiteral(dependency.location)), \(requirement))"
        }
    }

    private static func manifestRequirement(_ requirement: Requirement) throws -> String {
        switch requirement {
        case .exact(let version):
            return "exact: \(swiftStringLiteral(version.description))"
        case let .range(lower, upper):
            return "\(swiftStringLiteral(lower.description))..<\(swiftStringLiteral(upper.description))"
        case .revision(let revision):
            return "revision: \(swiftStringLiteral(revision))"
        case .branch(let branch):
            return "branch: \(swiftStringLiteral(branch))"
        }
    }

    private static func swiftStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private struct ResolvedFileSnapshot {
        let data: Data?
    }

    private static func resolveWithSwiftPackageManagerProcess(
        packageDir: URL,
        scratchDir: URL?,
        cacheDir: URL,
        registryConfigurationPath: URL?,
        defaultRegistryURL: String?,
        disableSandbox: Bool,
        scmToRegistryTransformation: SCMToRegistryTransformation,
        writeResolvedFile: Bool
    ) async throws -> ResolvedPins {
        let resolvedPath = packageDir.appendingPathComponent("Package.resolved")
        let snapshot = writeResolvedFile ? nil : try await snapshotResolvedFile(at: resolvedPath)

        do {
            try await SystemProcess.run(
                "swift",
                swiftPackageResolveArguments(
                    packageDir: packageDir,
                    scratchDir: scratchDir,
                    cacheDir: cacheDir,
                    registryConfigurationPath: registryConfigurationPath,
                    defaultRegistryURL: defaultRegistryURL,
                    disableSandbox: disableSandbox,
                    scmToRegistryTransformation: scmToRegistryTransformation
                ),
                workingDirectory: packageDir
            )
            let resolved = try await ResolvedFile.read(packageDir: packageDir)
            if let snapshot {
                try await restoreResolvedFile(snapshot, at: resolvedPath)
            }
            return resolved
        } catch {
            if let snapshot {
                try? await restoreResolvedFile(snapshot, at: resolvedPath)
            }
            throw error
        }
    }

    private static func swiftPackageResolveArguments(
        packageDir: URL,
        scratchDir: URL?,
        cacheDir: URL,
        registryConfigurationPath: URL?,
        defaultRegistryURL: String?,
        disableSandbox: Bool,
        scmToRegistryTransformation: SCMToRegistryTransformation
    ) -> [String] {
        var arguments = [
            "package",
            "--package-path",
            packageDir.path,
            "--cache-path",
            cacheDir.path,
        ]
        if let scratchDir {
            arguments.append(contentsOf: ["--scratch-path", scratchDir.path])
        }
        if let registryConfigurationPath {
            arguments.append(contentsOf: ["--config-path", registryConfigurationPath.path])
        }
        if let defaultRegistryURL {
            arguments.append(contentsOf: ["--default-registry-url", defaultRegistryURL])
        }
        if disableSandbox {
            arguments.append("--disable-sandbox")
        }
        switch scmToRegistryTransformation {
        case .disabled:
            arguments.append("--disable-scm-to-registry-transformation")
        case .useRegistryIdentityForSCM:
            arguments.append("--use-registry-identity-for-scm")
        case .replaceSCMWithRegistry:
            arguments.append("--replace-scm-with-registry")
        }
        arguments.append("resolve")
        return arguments
    }

    private static func snapshotResolvedFile(at path: URL) async throws -> ResolvedFileSnapshot {
        guard try await fileSystem.exists(path.absolutePath) else {
            return ResolvedFileSnapshot(data: nil)
        }
        return ResolvedFileSnapshot(data: try await fileSystem.readFile(at: path.absolutePath))
    }

    private static func restoreResolvedFile(_ snapshot: ResolvedFileSnapshot, at path: URL) async throws {
        if let data = snapshot.data {
            try await fileSystem.atomicWrite(data, to: path)
        } else {
            try await fileSystem.removePath(path)
        }
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
