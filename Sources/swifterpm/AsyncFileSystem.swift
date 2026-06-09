import Foundation
import NIOFileSystem

enum AsyncFileSystem {
    private static let fileSystem = FileSystem.shared

    static func createDirectory(at url: URL, withIntermediateDirectories: Bool) async throws {
        try await fileSystem.createDirectory(
            at: filePath(url),
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    static func exists(_ url: URL) async throws -> Bool {
        try await info(for: url, infoAboutSymbolicLink: true) != nil
    }

    static func isDirectoryAndNotSymlink(_ url: URL) async throws -> Bool {
        try await info(for: url, infoAboutSymbolicLink: true)?.type == .directory
    }

    static func isDirectory(_ url: URL) async throws -> Bool {
        try await info(for: url, infoAboutSymbolicLink: false)?.type == .directory
    }

    static func isRegularFile(_ url: URL) async throws -> Bool {
        try await info(for: url, infoAboutSymbolicLink: false)?.type == .regular
    }

    static func modificationDate(_ url: URL) async throws -> Date? {
        guard let info = try await info(for: url, infoAboutSymbolicLink: false) else {
            return nil
        }
        let modified = info.lastDataModificationTime
        return Date(
            timeIntervalSince1970: TimeInterval(modified.seconds) + TimeInterval(modified.nanoseconds) / 1_000_000_000
        )
    }

    static func readData(from url: URL, maximumSizeAllowed: ByteCount = .mebibytes(64)) async throws -> Data {
        let bytes = try await Array<UInt8>(
            contentsOf: filePath(url),
            maximumSizeAllowed: maximumSizeAllowed,
            fileSystem: fileSystem
        )
        return Data(bytes)
    }

    static func writeData(_ data: Data, to url: URL) async throws {
        try await createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try await Array(data).write(
                toFileAt: filePath(temp),
                options: .newFile(replaceExisting: false),
                fileSystem: fileSystem
            )
            try await fileSystem.replaceItem(at: filePath(url), withItemAt: filePath(temp))
        } catch {
            try? await removeItem(at: temp)
            throw error
        }
    }

    static func replaceFile(_ source: URL, at destination: URL) async throws {
        try await createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try await fileSystem.replaceItem(
                at: filePath(destination),
                withItemAt: filePath(source)
            )
        } catch {
            try? await removeItem(at: source)
            throw error
        }
    }

    static func removeItem(at url: URL) async throws {
        _ = try await fileSystem.removeItem(at: filePath(url))
    }

    static func moveItem(at source: URL, to destination: URL) async throws {
        try await fileSystem.moveItem(at: filePath(source), to: filePath(destination))
    }

    static func createSymbolicLink(at url: URL, withDestinationURL destination: URL) async throws {
        try await fileSystem.createSymbolicLink(
            at: filePath(url),
            withDestination: filePath(destination)
        )
    }

    static func copyItem(at source: URL, to destination: URL) async throws {
        try await fileSystem.copyItem(
            at: filePath(source),
            to: filePath(destination),
            strategy: .parallel(maxDescriptors: 16)
        )
    }

    static func contentsOfDirectory(at url: URL) async throws -> [URL] {
        try await fileSystem.withDirectoryHandle(atPath: filePath(url)) { directory in
            var entries: [URL] = []
            for try await entry in directory.listContents(recursive: false) {
                entries.append(URL(fileURLWithPath: entry.path.string))
            }
            return entries
        }
    }

    static func currentDirectoryPath() async throws -> String {
        try await fileSystem.currentWorkingDirectory.string
    }

    private static func info(for url: URL, infoAboutSymbolicLink: Bool) async throws -> FileInfo? {
        try await fileSystem.info(
            forFileAt: filePath(url),
            infoAboutSymbolicLink: infoAboutSymbolicLink
        )
    }

    private static func filePath(_ url: URL) -> FilePath {
        FilePath(url.path)
    }
}
