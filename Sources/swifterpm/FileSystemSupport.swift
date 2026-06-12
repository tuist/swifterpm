import FileSystem
import Foundation
import Path

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

let fileSystem = FileSystem()

extension URL {
    var absolutePath: AbsolutePath {
        get throws {
            try AbsolutePath(validating: path)
        }
    }
}

extension AbsolutePath {
    var fileURL: URL {
        URL(fileURLWithPath: pathString)
    }
}

extension URL {
    /// Path of `self` expressed relative to `base`, using `..` components as needed.
    /// Returns `"."` when `self` and `base` refer to the same path.
    /// Used to keep `.build/workspace-state.json` and the swifterpm package-info index
    /// relocatable: paths are anchored to `scratchDir` so a cached `.build/` works
    /// after the project tree moves to a different absolute location.
    func relativePathString(to base: URL) throws -> String {
        let relative = try absolutePath.relative(to: base.absolutePath).pathString
        return relative.isEmpty ? "." : relative
    }

    /// Returns `self` encoded relative to `scratchDir` only when it lives inside
    /// `packageDir`; otherwise returns the absolute path verbatim.
    ///
    /// This scopes the relative-path encoding to paths that are part of the consuming
    /// project (its scratch dir, in-tree binaries, and in-tree fileSystem deps). Paths
    /// that point outside the project tree (e.g. an external local fileSystem or
    /// `localSourceControl` dep on another disk location) are host-specific by nature
    /// and keep their absolute form, matching SwiftPM's `workspace-state.json` so the
    /// e2e differential suite still holds for those entries.
    func pathRelativeToScratchIfInsidePackage(
        scratchDir: URL, packageDir: URL
    ) throws -> String {
        // Relativize when this URL lives under either the project root (packageDir) or
        // the scratch dir. Both are project-scoped, so paths inside either are part of
        // the cacheable `.build/`-rooted unit. Paths outside both (typically external
        // local fileSystem / localSourceControl deps) stay absolute so SwiftPM-compat
        // against the e2e differential suite still holds for those entries.
        //
        // We normalize the macOS `/private/var` vs `/var` symlink layer with a string
        // substitution rather than POSIX `realpath`. realpath follows every symlink,
        // and on developer machines `<scratch>/swifterpm/artifacts/<id>/<target>` is a
        // symlink into the global cache; following it would make a path that's
        // logically inside scratch look like it lives outside.
        let selfNormalized = Self.normalizedPathString(path)
        let packageNormalized = Self.normalizedPathString(packageDir.path)
        let scratchNormalized = Self.normalizedPathString(scratchDir.path)

        let selfAbs = try AbsolutePath(validating: selfNormalized)
        let packageAbs = try AbsolutePath(validating: packageNormalized)
        let scratchAbs = try AbsolutePath(validating: scratchNormalized)

        let packageRelative = packageAbs == selfAbs ? "" : try selfAbs.relative(to: packageAbs).pathString
        let scratchRelative = scratchAbs == selfAbs ? "" : try selfAbs.relative(to: scratchAbs).pathString
        let insidePackage = !packageRelative.hasPrefix("..")
        let insideScratch = !scratchRelative.hasPrefix("..")
        guard insidePackage || insideScratch else {
            return path
        }
        return scratchRelative.isEmpty ? "." : scratchRelative
    }

    private static func normalizedPathString(_ value: String) -> String {
        value.replacingOccurrences(of: "/private/var/", with: "/var/")
    }
}

extension FileSystem {
    /// Write `data` atomically by writing to a temp sibling and then replacing the destination.
    /// Creates parent directories if missing.
    func write(_ data: Data, to url: URL) async throws {
        try await write(data, to: url.absolutePath)
    }

    func write(_ data: Data, to path: AbsolutePath) async throws {
        let parent = path.parentDirectory
        if !(try await exists(parent, isDirectory: true)) {
            try await makeDirectory(at: parent, options: [.createTargetParentDirectories])
        }
        // `Data.write(options: .atomic)` is synchronous, so offload it to a detached task to
        // avoid blocking the cooperative executor while the temp file is renamed into place.
        let url = path.fileURL
        try await Task.detached {
            try data.write(to: url, options: .atomic)
        }.value
    }

    /// Atomically write text to `url`, overwriting any existing file.
    func atomicWrite(_ string: String, to url: URL) async throws {
        try await atomicWrite(Data(string.utf8), to: url)
    }

    func atomicWrite(_ data: Data, to url: URL) async throws {
        try await write(data, to: url)
    }

    /// Remove the item at `url`. No-op if absent.
    func removePath(_ url: URL) async throws {
        try await remove(url.absolutePath)
    }

    /// List the contents of `url` as URLs.
    func contentsOfDirectory(at url: URL) async throws -> [URL] {
        try await contentsOfDirectory(url.absolutePath).map(\.fileURL)
    }

    /// True if a path is a directory and not a symbolic link.
    /// `FileSystem.exists(_:, isDirectory: true)` follows symlinks, so we need to use lstat here.
    /// Synchronous because `lstat` is a single non-blocking metadata call.
    func isDirectoryAndNotSymlink(_ url: URL) -> Bool {
        var stats = stat()
        let result = url.path.withCString { lstat($0, &stats) }
        guard result == 0 else { return false }
        return (stats.st_mode & S_IFMT) == S_IFDIR
    }

    /// True if a path exists or is a (potentially broken) symlink.
    /// Synchronous because `lstat` is a single non-blocking metadata call.
    func existsIncludingSymlinks(_ url: URL) -> Bool {
        var stats = stat()
        return url.path.withCString { lstat($0, &stats) } == 0
    }

    /// Create a temporary directory underneath `parent` and return its URL.
    func temporaryDirectory(in parent: URL) async throws -> URL {
        let parentPath = try parent.absolutePath
        try await makeDirectory(at: parentPath, options: [.createTargetParentDirectories])
        let url = parent.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try await makeDirectory(at: url.absolutePath, options: [.createTargetParentDirectories])
        return url
    }

    /// If `directory` contains exactly one subdirectory, replace `directory` with that subdirectory's contents.
    func flattenSingleDirectory(_ url: URL) async throws {
        let entries = try await contentsOfDirectory(url.absolutePath)
        guard entries.count == 1 else { return }
        let nested = entries[0].fileURL
        guard isDirectoryAndNotSymlink(nested) else { return }

        let temp = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).flattening")
        if try await exists(temp.absolutePath) {
            try await remove(temp.absolutePath)
        }
        try await move(from: nested.absolutePath, to: temp.absolutePath, options: [])
        try await remove(url.absolutePath)
        try await move(from: temp.absolutePath, to: url.absolutePath, options: [])
    }

    /// Materialise `source` at `destination`, removing any existing item first. On CI runners the
    /// directory is copied; otherwise we symlink (so callers see a stable path while the cached
    /// payload stays shared).
    func replaceWithCachedDirectory(source: URL, destination: URL) async throws {
        let destinationPath = try destination.absolutePath
        if existsIncludingSymlinks(destination) {
            try await remove(destinationPath)
        }
        try await makeDirectory(
            at: destinationPath.parentDirectory, options: [.createTargetParentDirectories]
        )
        if Environment.isCI {
            try await copy(source.absolutePath, to: destinationPath)
            return
        }
        try await createSymbolicLink(from: destinationPath, to: source.absolutePath)
    }

    func replaceWithSymlinkedDirectory(source: URL, destination: URL) async throws {
        try await replaceWithCachedDirectory(source: source, destination: destination)
    }
}
