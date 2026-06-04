import Foundation
import Testing

struct SupportTests {
    @Test
    func hashingAndRevisionHelpersAreStable() {
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(sha256Hex(Data("abc".utf8)) == expected)
        #expect(stableHash("abc") == expected)
        #expect(shortRevision("abcdef1234567890") == "abcdef123456")
    }

    @Test
    func atomicWriteCreatesParentDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let path = root.appendingPathComponent("nested/file.txt")
        try atomicWrite("hello", to: path)

        #expect(try String(contentsOf: path, encoding: .utf8) == "hello")
    }

    @Test
    func runCommandDrainsStdoutAndStderr() throws {
        let result = try runCommand("/bin/sh", ["-c", "printf out; printf err >&2"])

        #expect(result.stdoutString == "out")
        #expect(result.stderrString == "err")
    }

    @Test
    func filesystemHelpersFlattenAndSymlinkDirectoryContents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source")
        let nested = root.appendingPathComponent("outer/nested")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try atomicWrite("value", to: source.appendingPathComponent("file.txt"))
        try atomicWrite("nested", to: nested.appendingPathComponent("nested.txt"))

        try flattenSingleDirectory(root.appendingPathComponent("outer"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("outer/nested.txt").path))

        let destination = root.appendingPathComponent("destination")
        try replaceWithSymlinkedDirectoryContents(source: source, destination: destination)
        #expect(pathExistsOrIsSymlink(destination.appendingPathComponent("file.txt")))
        #expect(!isDirectoryAndNotSymlink(destination.appendingPathComponent("file.txt")))
    }

    @Test
    func temporaryDirectoryAndFileSafeNameUseScopedPaths() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let temp = try temporaryDirectory(in: root)

        #expect(temp.path.hasPrefix(root.path))
        #expect(FileManager.default.fileExists(atPath: temp.path))
        #expect(fileSafeName("a/b:c") == "a_b_c")
    }
}
