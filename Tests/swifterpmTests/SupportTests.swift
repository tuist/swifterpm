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
    func atomicWriteCreatesParentDirectories() async throws {
        try await withTemporaryDirectory { root in
            let path = root.appendingPathComponent("nested/file.txt")
            try await atomicWrite("hello", to: path)

            let data = try await AsyncFileSystem.readData(from: path)
            #expect(String(data: data, encoding: .utf8) == "hello")
        }
    }

    @Test
    func runCommandDrainsStdoutAndStderr() throws {
        let result = try runCommand("/bin/sh", ["-c", "printf out; printf err >&2"])

        #expect(result.stdoutString == "out")
        #expect(result.stderrString == "err")
    }

    @Test
    func filesystemHelpersFlattenAndSymlinkDirectoryContents() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            let nested = root.appendingPathComponent("outer/nested")
            try await AsyncFileSystem.createDirectory(at: source, withIntermediateDirectories: true)
            try await AsyncFileSystem.createDirectory(at: nested, withIntermediateDirectories: true)
            try await atomicWrite("value", to: source.appendingPathComponent("file.txt"))
            try await atomicWrite("nested", to: nested.appendingPathComponent("nested.txt"))

            try await flattenSingleDirectory(root.appendingPathComponent("outer"))
            #expect(try await AsyncFileSystem.exists(root.appendingPathComponent("outer/nested.txt")))

            let destination = root.appendingPathComponent("destination")
            try await replaceWithSymlinkedDirectoryContents(source: source, destination: destination)
            #expect(try await pathExistsOrIsSymlink(destination.appendingPathComponent("file.txt")))
            #expect(!(try await isDirectoryAndNotSymlink(destination.appendingPathComponent("file.txt"))))
        }
    }

    @Test
    func temporaryDirectoryAndFileSafeNameUseScopedPaths() async throws {
        try await withTemporaryDirectory { root in
            let temp = try await temporaryDirectory(in: root)

            #expect(temp.path.hasPrefix(root.path))
            #expect(try await AsyncFileSystem.exists(temp))
            #expect(fileSafeName("a/b:c") == "a_b_c")
        }
    }
}
