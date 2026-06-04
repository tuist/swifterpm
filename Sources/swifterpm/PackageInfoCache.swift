import Foundation

private struct PackageInfoIndex: Codable {
    let schemaVersion: Int
    let generatedAtUnix: UInt64
    let root: PackageInfoEntry
    let packages: [PackageInfoEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAtUnix = "generated_at_unix"
        case root
        case packages
    }
}

private struct PackageInfoEntry: Codable, Sendable {
    let identity: String
    let kind: String
    let location: String
    let version: String?
    let revision: String?
    let packagePath: String
    let packageInfoPath: String

    enum CodingKeys: String, CodingKey {
        case identity
        case kind
        case location
        case version
        case revision
        case packagePath = "package_path"
        case packageInfoPath = "package_info_path"
    }
}

func writePackageInfoCache(
    packageDir: URL,
    scratchDir: URL,
    resolved: ResolvedPins,
    cacheDir customCacheDir: URL?,
    disableSandbox: Bool,
    quiet: Bool
) async throws {
    let cacheDir = customCacheDir ?? scratchDir.appendingPathComponent("swifterpm/package-info")
    let scratchLock = try await pathLock(at: scratchDir.appendingPathComponent(".swifterpm.lock"))
    let cacheLock = try await pathLock(at: cacheDir.appendingPathComponent(".swifterpm.lock"))
    _ = scratchLock
    _ = cacheLock

    try await AsyncFileSystem.createDirectory(
        at: cacheDir.appendingPathComponent("packages"),
        withIntermediateDirectories: true
    )

    let rootPath = cacheDir.appendingPathComponent("root.json")
    try await writeDumpPackageJSON(packageDir: packageDir, destination: rootPath, disableSandbox: disableSandbox)
    let rootManifest = try JSONSerialization.jsonObject(with: try await AsyncFileSystem.readData(from: rootPath))

    let packagePins = resolved.pins
        .filter { isSourceControlKind($0.kind) || isRegistryKind($0.kind) }
        .sorted { $0.identity < $1.identity }

    let packages = try await withThrowingTaskGroup(of: PackageInfoEntry.self) { group in
        for pin in packagePins {
            group.addTask {
                let packagePath = try packagePathForPin(scratchDir: scratchDir, pin: pin)
                let packageInfoPath = cacheDir
                    .appendingPathComponent("packages")
                    .appendingPathComponent("\(fileSafeName(pin.identity))-\(entryHash(pin)).json")
                try await writeDumpPackageJSON(packageDir: packagePath, destination: packageInfoPath, disableSandbox: disableSandbox)
                return packageEntry(pin: pin, packagePath: packagePath, packageInfoPath: packageInfoPath)
            }
        }
        var entries: [PackageInfoEntry] = []
        for try await entry in group {
            entries.append(entry)
        }
        return entries.sorted { $0.identity < $1.identity }
    }

    var allPackages = packages
    var localDependencies = try parseManifestFileSystemDependencies(rootManifest)
    localDependencies.sort { $0.identity < $1.identity }
    for dependency in localDependencies {
        let packagePath = URL(fileURLWithPath: dependency.path)
        let packageInfoPath = cacheDir
            .appendingPathComponent("packages")
            .appendingPathComponent("\(fileSafeName(dependency.identity))-\(String(stableHash(dependency.path).prefix(16))).json")
        try await writeDumpPackageJSON(packageDir: packagePath, destination: packageInfoPath, disableSandbox: disableSandbox)
        allPackages.append(PackageInfoEntry(
            identity: dependency.identity,
            kind: "fileSystem",
            location: dependency.path,
            version: nil,
            revision: nil,
            packagePath: packagePath.path,
            packageInfoPath: packageInfoPath.path
        ))
    }

    let index = PackageInfoIndex(
        schemaVersion: 1,
        generatedAtUnix: UInt64(Date().timeIntervalSince1970),
        root: PackageInfoEntry(
            identity: "root",
            kind: "root",
            location: packageDir.path,
            version: nil,
            revision: resolved.originHash,
            packagePath: packageDir.path,
            packageInfoPath: rootPath.path
        ),
        packages: allPackages
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try await atomicWrite(try encoder.encode(index) + Data("\n".utf8), to: cacheDir.appendingPathComponent("index.json"))

    if !quiet {
        print("cached package manifest JSON into \(cacheDir.path)")
    }
}

private func packagePathForPin(scratchDir: URL, pin: ResolvedPin) throws -> URL {
    if isRegistryKind(pin.kind) {
        return scratchDir
            .appendingPathComponent("registry/downloads")
            .appendingPathComponent(try registryDownloadSubpath(pin))
    }
    return scratchDir
        .appendingPathComponent("checkouts")
        .appendingPathComponent(checkoutDirectoryName(pin))
}

private func writeDumpPackageJSON(packageDir: URL, destination: URL, disableSandbox: Bool) async throws {
    let data = try await dumpPackageJSON(packageDir: packageDir, disableSandbox: disableSandbox)
    try await atomicWrite(data, to: destination)
}

private func packageEntry(pin: ResolvedPin, packagePath: URL, packageInfoPath: URL) -> PackageInfoEntry {
    PackageInfoEntry(
        identity: pin.identity,
        kind: pin.kind,
        location: pin.location,
        version: pin.state.version,
        revision: pin.state.revision,
        packagePath: packagePath.path,
        packageInfoPath: packageInfoPath.path
    )
}

private func entryHash(_ pin: ResolvedPin) -> String {
    let input = "\(pin.location):\(pin.state.version ?? ""):\(pin.state.revision ?? "")"
    return String(stableHash(input).prefix(16))
}
