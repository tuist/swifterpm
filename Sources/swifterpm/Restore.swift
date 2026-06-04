import Foundation

func restorePackage(
    scratchDir: URL,
    cache: Cache,
    registryConfig: RegistryConfig,
    resolved: ResolvedPins,
    quiet: Bool
) async throws {
    let scratchLock = try await pathLock(at: scratchDir.appendingPathComponent(".swifterpm.lock"))
    _ = scratchLock
    let checkouts = scratchDir.appendingPathComponent("checkouts")
    let registryDownloads = scratchDir.appendingPathComponent("registry/downloads")
    async let createCheckouts: Void = AsyncFileSystem.createDirectory(at: checkouts, withIntermediateDirectories: true)
    async let createRegistryDownloads: Void = AsyncFileSystem.createDirectory(
        at: registryDownloads,
        withIntermediateDirectories: true
    )
    _ = try await (createCheckouts, createRegistryDownloads)

    let sourcePins = resolved.pins.filter { isSourceControlKind($0.kind) }
    let registryPins = resolved.pins.filter { isRegistryKind($0.kind) }
    let skipped = resolved.pins.count - sourcePins.count - registryPins.count

    async let restoredSources = restoreSourcePins(sourcePins, checkouts: checkouts, cache: cache)
    async let restoredRegistry = restoreRegistryPins(
        registryPins,
        registryDownloads: registryDownloads,
        cache: cache,
        registryConfig: registryConfig
    )

    let (sourceResults, registryResults) = try await (restoredSources, restoredRegistry)

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

private func restoreSourcePins(
    _ pins: [ResolvedPin],
    checkouts: URL,
    cache: Cache
) async throws -> [(String, URL)] {
    let results = try await parallelMap(pins) { pin in
        let source = try await ensureSource(cache: cache, pin: pin)
        let checkout = checkouts.appendingPathComponent(checkoutDirectoryName(pin))
        try await replaceWithSymlinkedDirectoryContents(source: source, destination: checkout)
        return (pin.identity, source)
    }
    return results.sorted { $0.0 < $1.0 }
}

private func restoreRegistryPins(
    _ pins: [ResolvedPin],
    registryDownloads: URL,
    cache: Cache,
    registryConfig: RegistryConfig
) async throws -> [(String, URL)] {
    let results = try await parallelMap(pins) { pin in
        let source = try await ensureRegistrySource(cache: cache, registryConfig: registryConfig, pin: pin)
        let download = registryDownloads.appendingPathComponent(try registryDownloadSubpath(pin))
        try await replaceWithSymlinkedDirectoryContents(source: source, destination: download)
        return (pin.identity, source)
    }
    return results.sorted { $0.0 < $1.0 }
}

func ensureSource(cache: Cache, pin: ResolvedPin) async throws -> URL {
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
    let temp = try await temporaryDirectory(in: parent)

    do {
        do {
            try await downloadGitHubArchive(cache: cache, pin: pin, destination: temp)
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

func ensureRegistrySource(cache: Cache, registryConfig: RegistryConfig, pin: ResolvedPin) async throws -> URL {
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
    let temp = try await temporaryDirectory(in: parent)

    do {
        try await downloadRegistryArchive(
            cache: cache,
            registryConfig: registryConfig,
            identity: pin.identity,
            version: try pin.versionString(),
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

private func downloadGitHubArchive(cache: Cache, pin: ResolvedPin, destination: URL) async throws {
    let repo = try GitHubRepo(location: pin.location)
    let revision = try pin.revision()
    let archivePath = cache.archivePath(url: pin.location, revision: revision)
    if !(try await AsyncFileSystem.exists(archivePath)) {
        let lock = try await cache.lock(namespace: "archives", key: archivePath.path)
        _ = lock
        if !(try await AsyncFileSystem.exists(archivePath)) {
            var headers = ["User-Agent": "swifterpm/0.1"]
            if let token = await githubToken() {
                headers["Authorization"] = "Bearer \(token)"
            }
            let url = URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.repo)/tarball/\(revision)")!
            try await httpDownload(url: url, destination: archivePath, headers: headers)
        }
    }

    try await runCommandAsync("/usr/bin/tar", ["-xzf", archivePath.path, "-C", destination.path])
    try await flattenSingleDirectory(destination)
    try await rejectArchiveWithSubmodules(destination)
}

private func shallowFetchCheckout(pin: ResolvedPin, destination: URL) async throws {
    let revision = try pin.revision()
    var lastError: (any Error)?
    for location in sourceControlFetchLocations(pin.location) {
        do {
            try await resetDirectory(destination)
            try await runCommandAsync("/usr/bin/git", ["init", destination.path])
            try await runCommandAsync("/usr/bin/git", ["-C", destination.path, "remote", "add", "origin", location])
            try await runCommandAsync("/usr/bin/git", ["-C", destination.path, "fetch", "--depth=1", "origin", revision])
            try await runCommandAsync("/usr/bin/git", ["-C", destination.path, "checkout", "--detach", "FETCH_HEAD"])
            try await runCommandAsync("/usr/bin/git", ["-C", destination.path, "submodule", "update", "--init", "--recursive"])
            let gitDir = destination.appendingPathComponent(".git")
            if try await localSourceControlPackageLocation(pin.location) == nil,
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

private func rejectArchiveWithSubmodules(_ destination: URL) async throws {
    if try await AsyncFileSystem.exists(destination.appendingPathComponent(".gitmodules")) {
        throw ToolError.message("\(destination.path) declares git submodules, which GitHub source archives do not include")
    }
}

private func resetDirectory(_ url: URL) async throws {
    if try await AsyncFileSystem.exists(url) {
        let entries = try await AsyncFileSystem.contentsOfDirectory(at: url)
        try await parallelForEach(entries) { entry in
            try await removePath(entry)
        }
    }
    try await AsyncFileSystem.createDirectory(at: url, withIntermediateDirectories: true)
}

func writeWorkspaceState(packageDir: URL, scratchDir: URL, resolved: ResolvedPins, disableSandbox: Bool) async throws {
    var dependencies: [[String: Any]] = []
    var artifacts: [[String: Any]] = []

    for pin in resolved.pins {
        if isSourceControlKind(pin.kind) {
            var checkoutState: [String: Any] = ["revision": try pin.revision()]
            if let branch = pin.state.branch { checkoutState["branch"] = branch }
            if let version = pin.state.version { checkoutState["version"] = version }
            dependencies.append([
                "basedOn": NSNull(),
                "packageRef": [
                    "identity": pin.identity,
                    "kind": pin.kind,
                    "location": pin.location,
                    "name": checkoutDirectoryName(pin),
                ],
                "state": [
                    "checkoutState": checkoutState,
                    "name": "sourceControlCheckout",
                ],
                "subpath": checkoutDirectoryName(pin),
            ])
            artifacts.append(contentsOf: try await discoverArtifacts(scratchDir: scratchDir, pin: pin))
        } else if isRegistryKind(pin.kind) {
            dependencies.append([
                "basedOn": NSNull(),
                "packageRef": [
                    "identity": pin.identity,
                    "kind": "registry",
                    "location": pin.identity,
                    "name": pin.identity,
                ],
                "state": [
                    "name": "registryDownload",
                    "version": try pin.versionString(),
                ],
                "subpath": try registryDownloadSubpath(pin),
            ])
            artifacts.append(contentsOf: try await discoverArtifacts(scratchDir: scratchDir, pin: pin))
        }
    }

    let manifest = try await dumpPackage(packageDir: packageDir, disableSandbox: disableSandbox)
    for dependency in try parseManifestFileSystemDependencies(manifest) {
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
    try await atomicWrite(try prettyJSONData(state), to: scratchDir.appendingPathComponent("workspace-state.json"))
}

private func discoverArtifacts(scratchDir: URL, pin: ResolvedPin) async throws -> [[String: Any]] {
    let artifactsDir = scratchDir.appendingPathComponent("artifacts").appendingPathComponent(pin.identity)
    guard try await AsyncFileSystem.exists(artifactsDir) else {
        return []
    }
    var artifacts: [[String: Any]] = []
    try await collectArtifacts(directory: artifactsDir, pin: pin, artifacts: &artifacts)
    return artifacts
}

private func collectArtifacts(directory: URL, pin: ResolvedPin, artifacts: inout [[String: Any]]) async throws {
    for entry in try await AsyncFileSystem.contentsOfDirectory(at: directory) {
        guard try await AsyncFileSystem.isDirectoryAndNotSymlink(entry) else { continue }
        if entry.pathExtension == "xcframework" {
            artifacts.append([
                "kind": ["xcframework": [:]],
                "packageRef": [
                    "identity": pin.identity,
                    "kind": pin.kind,
                    "location": pin.location,
                    "name": checkoutDirectoryName(pin),
                ],
                "path": entry.path,
                "targetName": entry.deletingPathExtension().lastPathComponent,
            ])
        } else {
            try await collectArtifacts(directory: entry, pin: pin, artifacts: &artifacts)
        }
    }
}
