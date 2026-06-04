import Foundation

enum WorkspaceRestorer {
    static func restorePackage(
        scratchDir: URL,
        cache: Cache,
        registryConfig: RegistryConfig,
        resolved: ResolvedPins,
        quiet: Bool,
        disableSandbox: Bool = false
    ) async throws {
        let scratchLock = try await PathLock.acquire(
            at: scratchDir.appendingPathComponent(".swifterpm.lock"))
        _ = scratchLock
        let checkouts = scratchDir.appendingPathComponent("checkouts")
        let registryDownloads = scratchDir.appendingPathComponent("registry/downloads")
        async let createCheckouts: Void = AsyncFileSystem.createDirectory(
            at: checkouts, withIntermediateDirectories: true
        )
        async let createRegistryDownloads: Void = AsyncFileSystem.createDirectory(
            at: registryDownloads,
            withIntermediateDirectories: true
        )
        _ = try await (createCheckouts, createRegistryDownloads)

        let sourcePins = resolved.pins.filter { PinKind.isSourceControl($0.kind) }
        let registryPins = resolved.pins.filter { PinKind.isRegistry($0.kind) }
        let skipped = resolved.pins.count - sourcePins.count - registryPins.count

        async let restoredSources = restoreSourcePins(
            sourcePins, checkouts: checkouts, cache: cache
        )
        async let restoredRegistry = restoreRegistryPins(
            registryPins,
            registryDownloads: registryDownloads,
            cache: cache,
            registryConfig: registryConfig
        )

        let (sourceResults, registryResults) = try await (restoredSources, restoredRegistry)

        try await restoreBinaryArtifacts(
            scratchDir: scratchDir,
            cache: cache,
            resolved: resolved,
            disableSandbox: disableSandbox,
            quiet: quiet
        )

        guard !quiet else { return }
        for (identity, source) in sourceResults {
            print("restored \(identity) -> \(source.path)")
        }
        for (identity, source) in registryResults {
            print("restored \(identity) -> \(source.path)")
        }
        print("restored \(sourceResults.count) source-control packages into \(checkouts.path)")
        print("restored \(registryResults.count) registry packages into \(registryDownloads.path)")
        if skipped > 0 {
            print("skipped \(skipped) unsupported pins")
        }
    }

    private static func restoreBinaryArtifacts(
        scratchDir: URL,
        cache: Cache,
        resolved: ResolvedPins,
        disableSandbox: Bool,
        quiet: Bool
    ) async throws {
        try await ConcurrentTasks.forEach(resolved.pins) { pin in
            guard PinKind.isSourceControl(pin.kind) || PinKind.isRegistry(pin.kind) else {
                return
            }
            let packagePath = try packagePathForPin(scratchDir: scratchDir, pin: pin)
            let manifest = try await ManifestLoader.dumpPackage(
                packageDir: packagePath,
                disableSandbox: disableSandbox
            )
            let binaryTargets = try ManifestParser.binaryTargets(manifest)
            for target in binaryTargets {
                try await restoreBinaryArtifact(
                    target,
                    pin: pin,
                    scratchDir: scratchDir,
                    cache: cache,
                    quiet: quiet
                )
            }
        }
    }

    private static func restoreBinaryArtifact(
        _ target: ManifestBinaryTarget,
        pin: ResolvedPin,
        scratchDir: URL,
        cache: Cache,
        quiet: Bool
    ) async throws {
        let cachedArtifact = cache.binaryArtifactPath(
            identity: pin.identity,
            targetName: target.name,
            checksum: target.checksum
        )
        if try await !AsyncFileSystem.exists(cachedArtifact) {
            let lock = try await cache.lock(namespace: "artifacts", key: cachedArtifact.path)
            _ = lock
            if try await !AsyncFileSystem.exists(cachedArtifact) {
                try await downloadBinaryArtifact(
                    target,
                    cache: cache,
                    destination: cachedArtifact
                )
            }
        }

        let scratchArtifact = scratchDir
            .appendingPathComponent("artifacts")
            .appendingPathComponent(pin.identity)
            .appendingPathComponent("\(target.name).xcframework")
        try await AsyncFileSystem.replaceWithSymlinkedDirectory(
            source: cachedArtifact,
            destination: scratchArtifact
        )

        if !quiet {
            print("restored \(pin.identity).\(target.name) -> \(cachedArtifact.path)")
        }
    }

    private static func downloadBinaryArtifact(
        _ target: ManifestBinaryTarget,
        cache: Cache,
        destination: URL
    ) async throws {
        let archivePath = cache.binaryArtifactArchivePath(
            url: target.url,
            checksum: target.checksum
        )
        if try await !AsyncFileSystem.exists(archivePath) {
            try await HTTPClient.download(
                url: artifactURL(target.url),
                destination: archivePath
            )
        }

        let checksum = try Hashing.sha256Hex(await AsyncFileSystem.readData(from: archivePath))
        guard checksum == target.checksum else {
            try? await AsyncFileSystem.removePath(archivePath)
            throw ToolError.message(
                "\(target.name) checksum mismatch: expected \(target.checksum), got \(checksum)"
            )
        }

        let temp = try await AsyncFileSystem.temporaryDirectory(
            in: destination.deletingLastPathComponent()
        )

        do {
            try await SystemProcess.run(
                "/usr/bin/unzip",
                ["-q", archivePath.path, "-d", temp.path]
            )
            let artifacts = try await xcframeworks(in: temp)
            guard
                let artifact = artifacts.first(where: {
                    $0.lastPathComponent == "\(target.name).xcframework"
                }) ?? artifacts.first
            else {
                throw ToolError.message("\(target.name) binary artifact archive has no xcframework")
            }

            if try await AsyncFileSystem.exists(destination) {
                try await AsyncFileSystem.removePath(destination)
            }
            try await AsyncFileSystem.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await AsyncFileSystem.moveItem(at: artifact, to: destination)
            try? await AsyncFileSystem.removePath(temp)
        } catch {
            try? await AsyncFileSystem.removePath(temp)
            throw error
        }
    }

    private static func artifactURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw ToolError.message("invalid binary artifact URL: \(value)")
        }
        return url
    }

    private static func packagePathForPin(scratchDir: URL, pin: ResolvedPin) throws -> URL {
        if PinKind.isRegistry(pin.kind) {
            return try scratchDir
                .appendingPathComponent("registry/downloads")
                .appendingPathComponent(PinKind.registryDownloadSubpath(pin))
        }
        return scratchDir
            .appendingPathComponent("checkouts")
            .appendingPathComponent(PinKind.checkoutDirectoryName(pin))
    }

    private static func xcframeworks(in directory: URL) async throws -> [URL] {
        var result: [URL] = []
        for entry in try await AsyncFileSystem.contentsOfDirectory(at: directory) {
            guard try await AsyncFileSystem.isDirectoryAndNotSymlink(entry) else { continue }
            if entry.pathExtension == "xcframework" {
                result.append(entry)
            } else {
                try result.append(contentsOf: await xcframeworks(in: entry))
            }
        }
        return result
    }

    private static func restoreSourcePins(
        _ pins: [ResolvedPin],
        checkouts: URL,
        cache: Cache
    ) async throws -> [(String, URL)] {
        let results = try await ConcurrentTasks.map(pins) { pin in
            let source = try await ensureSource(cache: cache, pin: pin)
            let checkout = checkouts.appendingPathComponent(PinKind.checkoutDirectoryName(pin))
            try await AsyncFileSystem.replaceWithSymlinkedDirectory(
                source: source, destination: checkout
            )
            return (pin.identity, source)
        }
        return results.sorted { $0.0 < $1.0 }
    }

    private static func restoreRegistryPins(
        _ pins: [ResolvedPin],
        registryDownloads: URL,
        cache: Cache,
        registryConfig: RegistryConfig
    ) async throws -> [(String, URL)] {
        let results = try await ConcurrentTasks.map(pins) { pin in
            let source = try await ensureRegistrySource(
                cache: cache, registryConfig: registryConfig, pin: pin
            )
            let download = try registryDownloads.appendingPathComponent(
                PinKind.registryDownloadSubpath(pin))
            try await AsyncFileSystem.replaceWithSymlinkedDirectory(
                source: source, destination: download
            )
            return (pin.identity, source)
        }
        return results.sorted { $0.0 < $1.0 }
    }

    static func ensureSource(cache: Cache, pin: ResolvedPin) async throws -> URL {
        let destination = try cache.sourcePath(pin: pin)
        let manifest = destination.appendingPathComponent("Package.swift")
        if try await AsyncFileSystem.exists(manifest) {
            return destination
        }

        let lock = try await cache.lock(namespace: "sources", key: destination.path)
        _ = lock
        if try await AsyncFileSystem.exists(manifest) {
            return destination
        }
        if try await AsyncFileSystem.exists(destination) {
            try await AsyncFileSystem.removeItem(at: destination)
        }
        let parent = destination.deletingLastPathComponent()
        try await AsyncFileSystem.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = try await AsyncFileSystem.temporaryDirectory(in: parent)

        do {
            do {
                try await downloadSourceArchive(cache: cache, pin: pin, destination: temp)
            } catch {
                try await resetDirectory(temp)
                try await shallowFetchCheckout(pin: pin, destination: temp)
            }

            do {
                try await AsyncFileSystem.moveItem(at: temp, to: destination)
            } catch {
                if try await AsyncFileSystem.exists(manifest) {
                    try? await AsyncFileSystem.removeItem(at: temp)
                    return destination
                }
                throw error
            }
        } catch {
            try? await AsyncFileSystem.removeItem(at: temp)
            throw error
        }
        return destination
    }

    static func ensureRegistrySource(cache: Cache, registryConfig: RegistryConfig, pin: ResolvedPin)
        async throws -> URL
    {
        let destination = try cache.sourcePath(pin: pin)
        let manifest = destination.appendingPathComponent("Package.swift")
        if try await AsyncFileSystem.exists(manifest) {
            return destination
        }

        let lock = try await cache.lock(namespace: "sources", key: destination.path)
        _ = lock
        if try await AsyncFileSystem.exists(manifest) {
            return destination
        }
        if try await AsyncFileSystem.exists(destination) {
            try await AsyncFileSystem.removeItem(at: destination)
        }
        let parent = destination.deletingLastPathComponent()
        try await AsyncFileSystem.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = try await AsyncFileSystem.temporaryDirectory(in: parent)

        do {
            try await RegistryClient.downloadArchive(
                cache: cache,
                registryConfig: registryConfig,
                identity: pin.identity,
                version: pin.versionString(),
                destination: temp
            )

            try await AsyncFileSystem.moveItem(at: temp, to: destination)
        } catch {
            try? await AsyncFileSystem.removeItem(at: temp)
            if try await AsyncFileSystem.exists(manifest) {
                return destination
            }
            throw error
        }
        return destination
    }

    private static func downloadSourceArchive(cache: Cache, pin: ResolvedPin, destination: URL)
        async throws
    {
        if (try? GitHubRepo(location: pin.location)) != nil, await GitHubAuth.hasSession() {
            try await downloadGitHubArchive(cache: cache, pin: pin, destination: destination)
            return
        }
        if let repo = try? GitLabRepo(location: pin.location),
           await GitLabAuth.hasSession(host: repo.host)
        {
            try await downloadGitLabArchive(cache: cache, pin: pin, destination: destination)
            return
        }
        throw ToolError.message(
            "no authenticated source archive endpoint available for \(pin.location)")
    }

    private static func downloadGitHubArchive(cache: Cache, pin: ResolvedPin, destination: URL)
        async throws
    {
        let repo = try GitHubRepo(location: pin.location)
        let revision = try pin.revision()
        let archivePath = cache.archivePath(url: pin.location, revision: revision)
        if try !(await AsyncFileSystem.exists(archivePath)) {
            let lock = try await cache.lock(namespace: "archives", key: archivePath.path)
            _ = lock
            if try !(await AsyncFileSystem.exists(archivePath)) {
                var headers = ["User-Agent": "swifterpm/0.1"]
                if let token = await GitHubAuth.token() {
                    headers["Authorization"] = "Bearer \(token)"
                }
                let url = URL(
                    string:
                    "https://api.github.com/repos/\(repo.owner)/\(repo.repo)/tarball/\(revision)"
                )!
                try await HTTPClient.download(url: url, destination: archivePath, headers: headers)
            }
        }

        try await SystemProcess.run(
            "/usr/bin/tar", ["-xzf", archivePath.path, "-C", destination.path]
        )
        try await AsyncFileSystem.flattenSingleDirectory(destination)
        try await rejectArchiveWithSubmodules(destination)
    }

    private static func downloadGitLabArchive(cache: Cache, pin: ResolvedPin, destination: URL)
        async throws
    {
        let repo = try GitLabRepo(location: pin.location)
        let revision = try pin.revision()
        let archivePath = cache.archivePath(url: pin.location, revision: revision)
        if try !(await AsyncFileSystem.exists(archivePath)) {
            let lock = try await cache.lock(namespace: "archives", key: archivePath.path)
            _ = lock
            if try !(await AsyncFileSystem.exists(archivePath)) {
                try await GitLabAPI.downloadArchive(
                    repo: repo, revision: revision, destination: archivePath
                )
            }
        }

        try await SystemProcess.run(
            "/usr/bin/tar", ["-xzf", archivePath.path, "-C", destination.path]
        )
        try await AsyncFileSystem.flattenSingleDirectory(destination)
        try await rejectArchiveWithSubmodules(destination)
    }

    private static func shallowFetchCheckout(pin: ResolvedPin, destination: URL) async throws {
        let revision = try pin.revision()
        var lastError: (any Error)?
        for location in SourceControlLocations.fetchCandidates(pin.location) {
            do {
                try await resetDirectory(destination)
                try await SystemProcess.run("/usr/bin/git", ["init", destination.path])
                try await SystemProcess.run(
                    "/usr/bin/git", ["-C", destination.path, "remote", "add", "origin", location]
                )
                try await SystemProcess.run(
                    "/usr/bin/git",
                    ["-C", destination.path, "fetch", "--depth=1", "origin", revision]
                )
                try await SystemProcess.run(
                    "/usr/bin/git", ["-C", destination.path, "checkout", "--detach", "FETCH_HEAD"]
                )
                try await SystemProcess.run(
                    "/usr/bin/git",
                    ["-C", destination.path, "submodule", "update", "--init", "--recursive"]
                )
                let gitDir = destination.appendingPathComponent(".git")
                if try await PackageResolver.localSourceControlPackageLocation(pin.location) == nil,
                   try await AsyncFileSystem.exists(gitDir)
                {
                    try await AsyncFileSystem.removeItem(at: gitDir)
                }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ToolError.message("failed to fetch \(pin.location)")
    }

    private static func rejectArchiveWithSubmodules(_ destination: URL) async throws {
        if try await AsyncFileSystem.exists(destination.appendingPathComponent(".gitmodules")) {
            throw ToolError.message(
                "\(destination.path) declares git submodules, which GitHub source archives do not include"
            )
        }
    }

    private static func resetDirectory(_ url: URL) async throws {
        if try await AsyncFileSystem.exists(url) {
            let entries = try await AsyncFileSystem.contentsOfDirectory(at: url)
            try await ConcurrentTasks.forEach(entries) { entry in
                try await AsyncFileSystem.removePath(entry)
            }
        }
        try await AsyncFileSystem.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func writeWorkspaceState(
        packageDir: URL, scratchDir: URL, resolved: ResolvedPins, disableSandbox: Bool
    ) async throws {
        var dependencies: [[String: Any]] = []
        var artifacts: [[String: Any]] = []
        let hasArtifactsRoot = try await AsyncFileSystem.exists(
            scratchDir.appendingPathComponent("artifacts"))

        for pin in resolved.pins {
            if PinKind.isSourceControl(pin.kind) {
                var checkoutState: [String: Any] = try ["revision": pin.revision()]
                if let branch = pin.state.branch { checkoutState["branch"] = branch }
                if let version = pin.state.version { checkoutState["version"] = version }
                dependencies.append([
                    "basedOn": NSNull(),
                    "packageRef": [
                        "identity": pin.identity,
                        "kind": pin.kind,
                        "location": pin.location,
                        "name": PinKind.checkoutDirectoryName(pin),
                    ],
                    "state": [
                        "checkoutState": checkoutState,
                        "name": "sourceControlCheckout",
                    ],
                    "subpath": PinKind.checkoutDirectoryName(pin),
                ])
                if hasArtifactsRoot {
                    try artifacts.append(
                        contentsOf: await discoverArtifacts(scratchDir: scratchDir, pin: pin))
                }
            } else if PinKind.isRegistry(pin.kind) {
                try dependencies.append([
                    "basedOn": NSNull(),
                    "packageRef": [
                        "identity": pin.identity,
                        "kind": "registry",
                        "location": pin.identity,
                        "name": pin.identity,
                    ],
                    "state": [
                        "name": "registryDownload",
                        "version": pin.versionString(),
                    ],
                    "subpath": PinKind.registryDownloadSubpath(pin),
                ])
                if hasArtifactsRoot {
                    try artifacts.append(
                        contentsOf: await discoverArtifacts(scratchDir: scratchDir, pin: pin))
                }
            }
        }

        let manifest = try await ManifestLoader.dumpPackage(
            packageDir: packageDir, disableSandbox: disableSandbox
        )
        for dependency in try ManifestParser.fileSystemDependencies(manifest) {
            dependencies.append([
                "basedOn": NSNull(),
                "packageRef": [
                    "identity": dependency.identity,
                    "kind": "fileSystem",
                    "location": dependency.path,
                    "name": dependency.name,
                    "path": dependency.path,
                ],
                "state": [
                    "name": "fileSystem",
                    "path": dependency.path,
                ],
                "subpath": dependency.identity,
            ])
        }

        let state: [String: Any] = [
            "object": [
                "artifacts": artifacts,
                "dependencies": dependencies,
                "prebuilts": [],
            ],
            "version": 7,
        ]
        try await AsyncFileSystem.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try await AsyncFileSystem.atomicWrite(
            JSONFormatter.prettyData(state),
            to: scratchDir.appendingPathComponent("workspace-state.json")
        )
    }

    private static func discoverArtifacts(scratchDir: URL, pin: ResolvedPin) async throws
        -> [[String:
                Any]]
    {
        let artifactsDir = scratchDir.appendingPathComponent("artifacts").appendingPathComponent(
            pin.identity)
        guard try await AsyncFileSystem.exists(artifactsDir) else {
            return []
        }
        var artifacts: [[String: Any]] = []
        try await collectArtifacts(directory: artifactsDir, pin: pin, artifacts: &artifacts)
        return artifacts
    }

    private static func collectArtifacts(
        directory: URL, pin: ResolvedPin, artifacts: inout [[String: Any]]
    ) async throws {
        for entry in try await AsyncFileSystem.contentsOfDirectory(at: directory) {
            if entry.pathExtension == "xcframework" {
                artifacts.append([
                    "kind": ["xcframework": [:]],
                    "packageRef": [
                        "identity": pin.identity,
                        "kind": pin.kind,
                        "location": pin.location,
                        "name": PinKind.checkoutDirectoryName(pin),
                    ],
                    "path": entry.path,
                    "targetName": entry.deletingPathExtension().lastPathComponent,
                ])
            } else if try await AsyncFileSystem.isDirectoryAndNotSymlink(entry) {
                try await collectArtifacts(directory: entry, pin: pin, artifacts: &artifacts)
            }
        }
    }
}
