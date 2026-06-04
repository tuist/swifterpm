import Foundation

func restorePackage(
    scratchDir: URL,
    cache: Cache,
    registryConfig: RegistryConfig,
    resolved: ResolvedPins,
    quiet: Bool
) async throws {
    let scratchLock = try PathLock(path: scratchDir.appendingPathComponent(".swifterpm.lock"))
    _ = scratchLock
    let checkouts = scratchDir.appendingPathComponent("checkouts")
    let registryDownloads = scratchDir.appendingPathComponent("registry/downloads")
    try FileManager.default.createDirectory(at: checkouts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: registryDownloads, withIntermediateDirectories: true)

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
    try await withThrowingTaskGroup(of: (String, URL).self) { group in
        for pin in pins {
            group.addTask {
                let source = try await ensureSource(cache: cache, pin: pin)
                let checkout = checkouts.appendingPathComponent(checkoutDirectoryName(pin))
                try replaceWithSymlinkedDirectoryContents(source: source, destination: checkout)
                return (pin.identity, source)
            }
        }
        return try await collectSortedTaskResults(group)
    }
}

private func restoreRegistryPins(
    _ pins: [ResolvedPin],
    registryDownloads: URL,
    cache: Cache,
    registryConfig: RegistryConfig
) async throws -> [(String, URL)] {
    try await withThrowingTaskGroup(of: (String, URL).self) { group in
        for pin in pins {
            group.addTask {
                let source = try await ensureRegistrySource(cache: cache, registryConfig: registryConfig, pin: pin)
                let download = registryDownloads.appendingPathComponent(try registryDownloadSubpath(pin))
                try replaceWithSymlinkedDirectoryContents(source: source, destination: download)
                return (pin.identity, source)
            }
        }
        return try await collectSortedTaskResults(group)
    }
}

private func collectSortedTaskResults(
    _ group: ThrowingTaskGroup<(String, URL), any Error>
) async throws -> [(String, URL)] {
    var results: [(String, URL)] = []
    for try await result in group {
        results.append(result)
    }
    return results.sorted { $0.0 < $1.0 }
}

func ensureSource(cache: Cache, pin: ResolvedPin) async throws -> URL {
    let destination = try cache.sourcePath(pin: pin)
    if FileManager.default.fileExists(atPath: destination.appendingPathComponent("Package.swift").path) {
        return destination
    }

    let lock = try cache.lock(namespace: "sources", key: destination.path)
    _ = lock
    if FileManager.default.fileExists(atPath: destination.appendingPathComponent("Package.swift").path) {
        return destination
    }
    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    let parent = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let temp = try temporaryDirectory(in: parent)
    defer { try? FileManager.default.removeItem(at: temp) }

    do {
        try await downloadGitHubArchive(cache: cache, pin: pin, destination: temp)
    } catch {
        try resetDirectory(temp)
        try await shallowFetchCheckout(pin: pin, destination: temp)
    }

    do {
        try FileManager.default.moveItem(at: temp, to: destination)
    } catch {
        if FileManager.default.fileExists(atPath: destination.appendingPathComponent("Package.swift").path) {
            return destination
        }
        throw error
    }
    return destination
}

func ensureRegistrySource(cache: Cache, registryConfig: RegistryConfig, pin: ResolvedPin) async throws -> URL {
    let destination = try cache.sourcePath(pin: pin)
    if FileManager.default.fileExists(atPath: destination.appendingPathComponent("Package.swift").path) {
        return destination
    }

    let lock = try cache.lock(namespace: "sources", key: destination.path)
    _ = lock
    if FileManager.default.fileExists(atPath: destination.appendingPathComponent("Package.swift").path) {
        return destination
    }
    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    let parent = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let temp = try temporaryDirectory(in: parent)
    defer { try? FileManager.default.removeItem(at: temp) }

    try await downloadRegistryArchive(
        cache: cache,
        registryConfig: registryConfig,
        identity: pin.identity,
        version: try pin.versionString(),
        destination: temp
    )

    do {
        try FileManager.default.moveItem(at: temp, to: destination)
    } catch {
        if FileManager.default.fileExists(atPath: destination.appendingPathComponent("Package.swift").path) {
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
    if !FileManager.default.fileExists(atPath: archivePath.path) {
        let lock = try cache.lock(namespace: "archives", key: archivePath.path)
        _ = lock
        if !FileManager.default.fileExists(atPath: archivePath.path) {
            var headers = ["User-Agent": "swifterpm/0.1"]
            if let token = githubToken() {
                headers["Authorization"] = "Bearer \(token)"
            }
            let url = URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.repo)/tarball/\(revision)")!
            try await httpDownload(url: url, destination: archivePath, headers: headers)
        }
    }

    try await runCommandAsync("/usr/bin/tar", ["-xzf", archivePath.path, "-C", destination.path])
    try flattenSingleDirectory(destination)
    try rejectArchiveWithSubmodules(destination)
}

private func shallowFetchCheckout(pin: ResolvedPin, destination: URL) async throws {
    let revision = try pin.revision()
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try await runCommandAsync("/usr/bin/git", ["init", destination.path])
    try await runCommandAsync("/usr/bin/git", ["-C", destination.path, "remote", "add", "origin", pin.location])
    try await runCommandAsync("/usr/bin/git", ["-C", destination.path, "fetch", "--depth=1", "origin", revision])
    try await runCommandAsync("/usr/bin/git", ["-C", destination.path, "checkout", "--detach", "FETCH_HEAD"])
    try await runCommandAsync("/usr/bin/git", ["-C", destination.path, "submodule", "update", "--init", "--recursive"])
    let gitDir = destination.appendingPathComponent(".git")
    if localSourceControlPackageLocation(pin.location) == nil,
       FileManager.default.fileExists(atPath: gitDir.path)
    {
        try FileManager.default.removeItem(at: gitDir)
    }
}

private func rejectArchiveWithSubmodules(_ destination: URL) throws {
    if FileManager.default.fileExists(atPath: destination.appendingPathComponent(".gitmodules").path) {
        throw ToolError.message("\(destination.path) declares git submodules, which GitHub source archives do not include")
    }
}

private func resetDirectory(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        for entry in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            try removePath(entry)
        }
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

func writeWorkspaceState(packageDir: URL, scratchDir: URL, resolved: ResolvedPins, disableSandbox: Bool) throws {
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
            artifacts.append(contentsOf: try discoverArtifacts(scratchDir: scratchDir, pin: pin))
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
            artifacts.append(contentsOf: try discoverArtifacts(scratchDir: scratchDir, pin: pin))
        }
    }

    let manifest = try dumpPackage(packageDir: packageDir, disableSandbox: disableSandbox)
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
    try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    try atomicWrite(try prettyJSONData(state), to: scratchDir.appendingPathComponent("workspace-state.json"))
}

private func discoverArtifacts(scratchDir: URL, pin: ResolvedPin) throws -> [[String: Any]] {
    let artifactsDir = scratchDir.appendingPathComponent("artifacts").appendingPathComponent(pin.identity)
    guard FileManager.default.fileExists(atPath: artifactsDir.path) else {
        return []
    }
    var artifacts: [[String: Any]] = []
    try collectArtifacts(directory: artifactsDir, pin: pin, artifacts: &artifacts)
    return artifacts
}

private func collectArtifacts(directory: URL, pin: ResolvedPin, artifacts: inout [[String: Any]]) throws {
    for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
        let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { continue }
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
            try collectArtifacts(directory: entry, pin: pin, artifacts: &artifacts)
        }
    }
}
