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

enum PackageInfoCacheWriter {
    static func write(
        packageDir: URL,
        scratchDir: URL,
        resolved: ResolvedPins,
        cacheDir customCacheDir: URL?,
        disableSandbox: Bool,
        quiet: Bool
    ) async throws {
        let cacheDir = customCacheDir ?? scratchDir.appendingPathComponent("swifterpm/package-info")
        let scratchLock = try await PathLock.acquire(
            at: scratchDir.appendingPathComponent(".swifterpm.lock"))
        let cacheLock = try await PathLock.acquire(
            at: cacheDir.appendingPathComponent(".swifterpm.lock"))
        _ = scratchLock
        _ = cacheLock

        try await AsyncFileSystem.createDirectory(
            at: cacheDir.appendingPathComponent("packages"),
            withIntermediateDirectories: true
        )

        let rootPath = cacheDir.appendingPathComponent("root.json")
        let rootManifestData = try await cachedOrDumpPackageJSON(
            packageDir: packageDir, destination: rootPath, disableSandbox: disableSandbox)
        let rootManifest = try JSONSerialization.jsonObject(
            with: rootManifestData)

        let packagePins = resolved.pins
            .filter { PinKind.isSourceControl($0.kind) || PinKind.isRegistry($0.kind) }
            .sorted { $0.identity < $1.identity }

        let packages = try await withThrowingTaskGroup(of: PackageInfoEntry.self) { group in
            for pin in packagePins {
                group.addTask {
                    let packagePath = try packagePathForPin(scratchDir: scratchDir, pin: pin)
                    let packageInfoPath =
                        cacheDir
                        .appendingPathComponent("packages")
                        .appendingPathComponent(
                            "\(SafeFileName.make(pin.identity))-\(entryHash(pin)).json")
                    _ = try await cachedOrDumpPackageJSON(
                        packageDir: packagePath, destination: packageInfoPath,
                        disableSandbox: disableSandbox)
                    return packageEntry(
                        pin: pin, packagePath: packagePath, packageInfoPath: packageInfoPath)
                }
            }
            var entries: [PackageInfoEntry] = []
            for try await entry in group {
                entries.append(entry)
            }
            return entries.sorted { $0.identity < $1.identity }
        }

        var allPackages = packages
        var localDependencies = try ManifestParser.fileSystemDependencies(rootManifest)
        localDependencies.sort { $0.identity < $1.identity }
        for dependency in localDependencies {
            let packagePath = URL(fileURLWithPath: dependency.path)
            let packageInfoPath =
                cacheDir
                .appendingPathComponent("packages")
                .appendingPathComponent(
                    "\(SafeFileName.make(dependency.identity))-\(String(Hashing.stable(dependency.path).prefix(16))).json"
                )
            _ = try await cachedOrDumpPackageJSON(
                packageDir: packagePath, destination: packageInfoPath,
                disableSandbox: disableSandbox)
            allPackages.append(
                PackageInfoEntry(
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
        try await AsyncFileSystem.atomicWrite(
            try encoder.encode(index) + Data("\n".utf8),
            to: cacheDir.appendingPathComponent("index.json")
        )

        if !quiet {
            print("cached package manifest JSON into \(cacheDir.path)")
        }
    }

    private static func packagePathForPin(scratchDir: URL, pin: ResolvedPin) throws -> URL {
        if PinKind.isRegistry(pin.kind) {
            return
                scratchDir
                .appendingPathComponent("registry/downloads")
                .appendingPathComponent(try PinKind.registryDownloadSubpath(pin))
        }
        return
            scratchDir
            .appendingPathComponent("checkouts")
            .appendingPathComponent(PinKind.checkoutDirectoryName(pin))
    }

    private static func cachedOrDumpPackageJSON(
        packageDir: URL, destination: URL, disableSandbox: Bool
    ) async throws -> Data {
        if try await isFreshPackageInfo(destination: destination, packageDir: packageDir) {
            return try await AsyncFileSystem.readData(from: destination)
        }
        let data = try await ManifestLoader.dumpPackageJSON(
            packageDir: packageDir, disableSandbox: disableSandbox)
        try await AsyncFileSystem.atomicWrite(data, to: destination)
        return data
    }

    private static func isFreshPackageInfo(destination: URL, packageDir: URL) async throws -> Bool {
        guard
            let cacheDate = try await AsyncFileSystem.modificationDate(destination),
            let manifestDate = try await AsyncFileSystem.modificationDate(
                packageDir.appendingPathComponent("Package.swift"))
        else {
            return false
        }
        return cacheDate >= manifestDate
    }

    private static func packageEntry(pin: ResolvedPin, packagePath: URL, packageInfoPath: URL)
        -> PackageInfoEntry
    {
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

    private static func entryHash(_ pin: ResolvedPin) -> String {
        let input = "\(pin.location):\(pin.state.version ?? ""):\(pin.state.revision ?? "")"
        return String(Hashing.stable(input).prefix(16))
    }
}
