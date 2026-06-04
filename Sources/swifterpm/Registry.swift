import Foundation

struct RegistryConfig: Sendable {
    private var defaultRegistryURL: URL?
    private var scopedRegistryURLs: [String: URL] = [:]

    static func load(packageDir: URL, configPath: URL?, defaultRegistryURL: String?) throws -> RegistryConfig {
        var config = RegistryConfig()
        if let global = globalRegistriesPath() {
            try config.mergeFile(global)
        }
        try config.mergeFile(packageDir.appendingPathComponent(".swiftpm/configuration/registries.json"))
        if let configPath {
            try config.mergeFile(registriesPath(fromConfigPath: configPath))
        }
        if let defaultRegistryURL {
            config.defaultRegistryURL = try parseRegistryURL(defaultRegistryURL)
        }
        return config
    }

    func registryURL(for identity: String) throws -> URL {
        let (scope, _) = try registryIdentityParts(identity)
        if let scoped = scopedRegistryURLs[scope] ?? scopedRegistryURLs[scope.lowercased()] {
            return scoped
        }
        if let defaultRegistryURL {
            return defaultRegistryURL
        }
        throw fail("no registry configured for '\(scope)' scope")
    }

    private mutating func mergeFile(_ path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any],
              let registries = root["registries"] as? [String: Any]
        else {
            return
        }
        for (scope, value) in registries {
            guard let entry = value as? [String: Any],
                  let urlString = entry["url"] as? String
            else {
                continue
            }
            let url = try parseRegistryURL(urlString)
            if scope == "[default]" {
                defaultRegistryURL = url
            } else {
                scopedRegistryURLs[scope.lowercased()] = url
            }
        }
    }
}

struct RegistryVersion: Codable, Sendable {
    let version: String

    var semver: SemVer? {
        try? SemVer(version)
    }
}

private struct RegistryVersionsCache: Codable {
    let registryURL: String
    let identity: String
    let versions: [RegistryVersion]
}

func registryVersions(identity: String, registryConfig: RegistryConfig, cache: Cache) async throws -> [RegistryVersion] {
    let registryURL = try registryConfig.registryURL(for: identity)
    if let cached = try readCachedRegistryVersions(cache: cache, registryURL: registryURL.absoluteString, identity: identity) {
        return cached
    }
    let lock = try cache.lock(namespace: "registry-versions", key: "\(registryURL.absoluteString):\(identity)")
    _ = lock
    if let cached = try readCachedRegistryVersions(cache: cache, registryURL: registryURL.absoluteString, identity: identity) {
        return cached
    }
    let versions = try await fetchRegistryVersions(registryURL: registryURL, identity: identity)
    try writeCachedRegistryVersions(cache: cache, registryURL: registryURL.absoluteString, identity: identity, versions: versions)
    return versions
}

func downloadRegistryArchive(
    cache: Cache,
    registryConfig: RegistryConfig,
    identity: String,
    version: String,
    destination: URL
) async throws {
    let registryURL = try registryConfig.registryURL(for: identity)
    let archivePath = cache.registryArchivePath(identity: identity, version: version)
    if !FileManager.default.fileExists(atPath: archivePath.path) {
        let lock = try cache.lock(namespace: "registry-archives", key: archivePath.path)
        _ = lock
        if !FileManager.default.fileExists(atPath: archivePath.path) {
            let expectedChecksum = try await fetchSourceArchiveChecksum(registryURL: registryURL, identity: identity, version: version)
            let data = try await fetchRegistryArchive(registryURL: registryURL, identity: identity, version: version)
            let actual = sha256Hex(data)
            guard actual.caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
                throw fail("\(identity) \(version) checksum mismatch: expected \(expectedChecksum), got \(actual)")
            }
            try atomicWrite(data, to: archivePath)
        }
    }

    try runCommand("/usr/bin/unzip", ["-q", archivePath.path, "-d", destination.path])
    try flattenSingleDirectory(destination)
}

private func fetchRegistryVersions(registryURL: URL, identity: String) async throws -> [RegistryVersion] {
    struct ReleasesResponse: Decodable {
        struct Release: Decodable { let problem: String? }
        let releases: [String: Release]
    }
    let data = try await httpData(url: try packageURL(registryURL: registryURL, identity: identity), headers: ["Accept": "application/vnd.swift.registry.v1+json"])
    let response = try JSONDecoder().decode(ReleasesResponse.self, from: data)
    return response.releases.compactMap { version, release in
        guard release.problem == nil, let semver = try? SemVer(version) else { return nil }
        return RegistryVersion(version: semver.description)
    }.sorted { ($0.semver ?? SemVer(major: 0, minor: 0, patch: 0)) < ($1.semver ?? SemVer(major: 0, minor: 0, patch: 0)) }
}

private func fetchSourceArchiveChecksum(registryURL: URL, identity: String, version: String) async throws -> String {
    struct ReleaseInfo: Decodable {
        struct Resource: Decodable {
            let name: String
            let type: String
            let checksum: String
        }
        let resources: [Resource]
    }
    let data = try await httpData(url: try packageURL(registryURL: registryURL, identity: identity, version: version), headers: ["Accept": "application/vnd.swift.registry.v1+json"])
    let info = try JSONDecoder().decode(ReleaseInfo.self, from: data)
    guard let resource = info.resources.first(where: { $0.name == "source-archive" && $0.type == "application/zip" }) else {
        throw fail("\(identity) \(version) does not declare a source archive checksum")
    }
    return resource.checksum
}

private func fetchRegistryArchive(registryURL: URL, identity: String, version: String) async throws -> Data {
    let (scope, name) = try registryIdentityParts(identity)
    let url = registryURL.appendingPathComponents([scope, name, "\(version).zip"])
    return try await httpData(url: url, headers: ["Accept": "application/vnd.swift.registry.v1+zip"])
}

private func packageURL(registryURL: URL, identity: String, version: String? = nil) throws -> URL {
    let (scope, name) = try registryIdentityParts(identity)
    var components = [scope, name]
    if let version {
        components.append(version)
    }
    return registryURL.appendingPathComponents(components)
}

private func parseRegistryURL(_ url: String) throws -> URL {
    guard let parsed = URL(string: url), parsed.scheme == "https" else {
        throw fail("registry URL must use https: \(url)")
    }
    return parsed
}

private func registriesPath(fromConfigPath configPath: URL) -> URL {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: configPath.path, isDirectory: &isDirectory), !isDirectory.boolValue {
        return configPath
    }
    return configPath.appendingPathComponent("registries.json")
}

private func globalRegistriesPath() -> URL? {
    ProcessInfo.processInfo.environment["HOME"].map {
        URL(fileURLWithPath: $0).appendingPathComponent(".swiftpm/configuration/registries.json")
    }
}

private func readCachedRegistryVersions(cache: Cache, registryURL: String, identity: String) throws -> [RegistryVersion]? {
    let path = cache.registryVersionsPath(registryURL: registryURL, identity: identity)
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
    if let modified = attrs[.modificationDate] as? Date,
       Date().timeIntervalSince(modified) > 60 * 60
    {
        return nil
    }
    let cached = try JSONDecoder().decode(RegistryVersionsCache.self, from: Data(contentsOf: path))
    guard cached.registryURL == registryURL, cached.identity == identity else { return nil }
    return cached.versions
}

private func writeCachedRegistryVersions(cache: Cache, registryURL: String, identity: String, versions: [RegistryVersion]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(RegistryVersionsCache(registryURL: registryURL, identity: identity, versions: versions)) + Data("\n".utf8)
    try atomicWrite(data, to: cache.registryVersionsPath(registryURL: registryURL, identity: identity))
}
