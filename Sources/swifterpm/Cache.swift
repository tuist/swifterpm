import Foundation

struct Cache: Sendable {
    let root: URL

    init(root: URL?) throws {
        if let root {
            self.root = root
        } else {
            self.root = try Cache.defaultRoot()
        }
        for path in [
            "sources",
            "archives",
            "registry/archives",
            "metadata/remotes",
            "metadata/registries",
            "locks",
            "virtual/checkouts",
        ] {
            try FileManager.default.createDirectory(
                at: self.root.appendingPathComponent(path),
                withIntermediateDirectories: true
            )
        }
    }

    func sourcePath(pin: ResolvedPin) throws -> URL {
        if pin.kind == "registry" {
            return root
                .appendingPathComponent("sources")
                .appendingPathComponent(pin.identity)
                .appendingPathComponent("\(try pin.versionString())-registry")
        }
        let version = pin.state.version ?? pin.state.branch ?? "revision"
        return root
            .appendingPathComponent("sources")
            .appendingPathComponent(pin.identity)
            .appendingPathComponent("\(version)-\(shortRevision(try pin.revision()))")
    }

    func archivePath(url: String, revision: String) -> URL {
        root
            .appendingPathComponent("archives")
            .appendingPathComponent("\(stableHash(url))-\(shortRevision(revision)).tar.gz")
    }

    func registryArchivePath(identity: String, version: String) -> URL {
        root
            .appendingPathComponent("registry/archives")
            .appendingPathComponent("\(stableHash(identity))-\(version).zip")
    }

    func remoteVersionsPath(location: String) -> URL {
        root
            .appendingPathComponent("metadata/remotes")
            .appendingPathComponent("\(stableHash(location)).json")
    }

    func registryVersionsPath(registryURL: String, identity: String) -> URL {
        root
            .appendingPathComponent("metadata/registries")
            .appendingPathComponent("\(stableHash(registryURL))-\(stableHash(identity)).json")
    }

    func lock(namespace: String, key: String) throws -> PathLock {
        try PathLock(path: root.appendingPathComponent("locks").appendingPathComponent(namespace).appendingPathComponent("\(stableHash(key)).lock"))
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
