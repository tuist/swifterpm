import Foundation

struct Cache: Sendable {
    let root: URL

    init(root: URL?) async throws {
        if let root {
            self.root = root
        } else {
            self.root = try Cache.defaultRoot()
        }
        let cacheRoot = self.root
        let topLevelPaths = [
            "sources",
            "archives",
            "registry",
            "metadata",
            "locks",
            "virtual",
        ]
        try await ConcurrentTasks.forEach(topLevelPaths) { path in
            try await AsyncFileSystem.createDirectory(
                at: cacheRoot.appendingPathComponent(path),
                withIntermediateDirectories: true
            )
        }
        try await ConcurrentTasks.forEach([
            "registry/archives",
            "metadata/remotes",
            "metadata/registries",
            "virtual/checkouts",
        ]) { path in
            try await AsyncFileSystem.createDirectory(
                at: cacheRoot.appendingPathComponent(path),
                withIntermediateDirectories: false
            )
        }
    }

    func sourcePath(pin: ResolvedPin) throws -> URL {
        if pin.kind == "registry" {
            return
                root
                .appendingPathComponent("sources")
                .appendingPathComponent(pin.identity)
                .appendingPathComponent("\(try pin.versionString())-registry")
        }
        let version = pin.state.version ?? pin.state.branch ?? "revision"
        return
            root
            .appendingPathComponent("sources")
            .appendingPathComponent(pin.identity)
            .appendingPathComponent("\(version)-\(Hashing.shortRevision(try pin.revision()))")
    }

    func archivePath(url: String, revision: String) -> URL {
        root
            .appendingPathComponent("archives")
            .appendingPathComponent(
                "\(Hashing.stable(url))-\(Hashing.shortRevision(revision)).tar.gz")
    }

    func registryArchivePath(identity: String, version: String) -> URL {
        root
            .appendingPathComponent("registry/archives")
            .appendingPathComponent("\(Hashing.stable(identity))-\(version).zip")
    }

    func remoteVersionsPath(location: String) -> URL {
        root
            .appendingPathComponent("metadata/remotes")
            .appendingPathComponent("\(Hashing.stable(location)).json")
    }

    func registryVersionsPath(registryURL: String, identity: String) -> URL {
        root
            .appendingPathComponent("metadata/registries")
            .appendingPathComponent(
                "\(Hashing.stable(registryURL))-\(Hashing.stable(identity)).json")
    }

    func lock(namespace: String, key: String) async throws -> PathLock {
        try await PathLock.acquire(
            at: root.appendingPathComponent("locks").appendingPathComponent(namespace)
                .appendingPathComponent("\(Hashing.stable(key)).lock")
        )
    }

    private static func defaultRoot() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_CACHE_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg).appendingPathComponent("swifterpm")
        }
        if let home = env["HOME"], home.hasPrefix("/") {
            return URL(fileURLWithPath: home).appendingPathComponent(".cache/swifterpm")
        }
        throw ToolError.message("could not find user cache directory from XDG_CACHE_HOME or HOME")
    }
}
