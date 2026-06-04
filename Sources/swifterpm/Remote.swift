import Foundation

struct RemoteVersion: Codable, Sendable {
    let version: String
    let revision: String

    var semver: SemVer? {
        try? SemVer(version)
    }
}

private struct RemoteVersionsCache: Codable {
    let location: String
    let versions: [RemoteVersion]
}

func remoteVersions(location: String, cache: Cache) async throws -> [RemoteVersion] {
    if let cached = try readCachedRemoteVersions(cache: cache, location: location) {
        return cached
    }
    let lock = try cache.lock(namespace: "remote-versions", key: location)
    _ = lock
    if let cached = try readCachedRemoteVersions(cache: cache, location: location) {
        return cached
    }
    let versions = try await fetchRemoteVersions(location: location)
    try writeCachedRemoteVersions(cache: cache, location: location, versions: versions)
    return versions
}

private func fetchRemoteVersions(location: String) async throws -> [RemoteVersion] {
    let gitVersions = (try? gitRemoteVersions(location: location)) ?? []
    if !gitVersions.isEmpty {
        return gitVersions
    }
    guard let repo = try? GitHubRepo(location: location) else {
        return []
    }
    return try await githubRemoteVersions(repo: repo)
}

private func gitRemoteVersions(location: String) throws -> [RemoteVersion] {
    let output = try commandOutput("/usr/bin/git", ["ls-remote", "--tags", location])
    var peeled: [String: String] = [:]
    var direct: [String: String] = [:]
    for line in output.split(separator: "\n") {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { continue }
        let sha = String(parts[0])
        let refName = String(parts[1])
        guard refName.hasPrefix("refs/tags/") else { continue }
        var tag = String(refName.dropFirst("refs/tags/".count))
        if tag.hasSuffix("^{}") {
            tag = String(tag.dropLast(3))
            peeled[tag] = sha
        } else {
            direct[tag] = sha
        }
    }

    var versions: [RemoteVersion] = []
    for (tag, sha) in direct {
        guard let version = parseSwiftTagVersion(tag) else { continue }
        versions.append(RemoteVersion(version: version.description, revision: peeled[tag] ?? sha))
    }
    return versions.sorted { (try? SemVer($0.version)) ?? SemVer(major: 0, minor: 0, patch: 0) < ((try? SemVer($1.version)) ?? SemVer(major: 0, minor: 0, patch: 0)) }
}

private func githubRemoteVersions(repo: GitHubRepo) async throws -> [RemoteVersion] {
    struct TagsResponse: Decodable {
        struct Commit: Decodable { let sha: String }
        let name: String
        let commit: Commit
    }

    var versions: [RemoteVersion] = []
    var page = 1
    while true {
        let url = URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.repo)/tags?per_page=100&page=\(page)")!
        var headers = ["User-Agent": "swifterpm/0.1"]
        if let token = githubToken() {
            headers["Authorization"] = "Bearer \(token)"
        }
        let tags = try JSONDecoder().decode([TagsResponse].self, from: await httpData(url: url, headers: headers))
        if tags.isEmpty {
            break
        }
        for tag in tags {
            if let version = parseSwiftTagVersion(tag.name) {
                versions.append(RemoteVersion(version: version.description, revision: tag.commit.sha))
            }
        }
        page += 1
    }
    return versions.sorted { (try? SemVer($0.version)) ?? SemVer(major: 0, minor: 0, patch: 0) < ((try? SemVer($1.version)) ?? SemVer(major: 0, minor: 0, patch: 0)) }
}

func resolveNamedRef(location: String, name: String) throws -> String {
    let output = try commandOutput("/usr/bin/git", ["ls-remote", location, name])
    guard let line = output.split(separator: "\n").first,
          let revision = line.split(whereSeparator: \.isWhitespace).first
    else {
        throw ToolError.message("\(name) was not found in \(location)")
    }
    return String(revision)
}

func parseSwiftTagVersion(_ tag: String) -> SemVer? {
    let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    return try? SemVer(value)
}

private func readCachedRemoteVersions(cache: Cache, location: String) throws -> [RemoteVersion]? {
    let path = cache.remoteVersionsPath(location: location)
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
    if let modified = attrs[.modificationDate] as? Date,
       Date().timeIntervalSince(modified) > 60 * 60
    {
        return nil
    }
    let cached = try JSONDecoder().decode(RemoteVersionsCache.self, from: Data(contentsOf: path))
    guard cached.location == location else { return nil }
    return cached.versions
}

private func writeCachedRemoteVersions(cache: Cache, location: String, versions: [RemoteVersion]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(RemoteVersionsCache(location: location, versions: versions)) + Data("\n".utf8)
    try atomicWrite(data, to: cache.remoteVersionsPath(location: location))
}
