import Foundation
import Testing
@testable import SwifterPMCore

struct SupportTests {
    @Test
    func hashingAndRevisionHelpersAreStable() {
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(Hashing.sha256Hex(Data("abc".utf8)) == expected)
        #expect(Hashing.stable("abc") == expected)
        #expect(Hashing.shortRevision("abcdef1234567890") == "abcdef123456")
    }

    @Test
    func atomicWriteCreatesParentDirectories() async throws {
        try await withTemporaryDirectory { root in
            let path = root.appendingPathComponent("nested/file.txt")
            try await AsyncFileSystem.atomicWrite("hello", to: path)

            let data = try await AsyncFileSystem.readData(from: path)
            #expect(String(data: data, encoding: .utf8) == "hello")
        }
    }

    @Test
    func systemProcessDrainsStdoutAndStderr() async throws {
        let result = try await SystemProcess.run("/bin/sh", ["-c", "printf out; printf err >&2"])

        #expect(result.stdoutString == "out")
        #expect(result.stderrString == "err")
    }

    @Test
    func concurrentTaskMapPreservesInputOrder() async throws {
        let values = [0, 1, 2, 3]
        let mapped = try await ConcurrentTasks.map(values, maxConcurrentTasks: 4) { value in
            try await Task.sleep(nanoseconds: UInt64((values.count - value) * 1_000_000))
            return value
        }

        #expect(mapped == values)
    }

    @Test
    func filesystemHelpersFlattenAndSymlinkDirectory() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            let nested = root.appendingPathComponent("outer/nested")
            try await AsyncFileSystem.createDirectory(at: source, withIntermediateDirectories: true)
            try await AsyncFileSystem.createDirectory(at: nested, withIntermediateDirectories: true)
            try await AsyncFileSystem.atomicWrite(
                "value", to: source.appendingPathComponent("file.txt"))
            try await AsyncFileSystem.atomicWrite(
                "nested", to: nested.appendingPathComponent("nested.txt"))

            try await AsyncFileSystem.flattenSingleDirectory(root.appendingPathComponent("outer"))
            #expect(
                try await AsyncFileSystem.exists(root.appendingPathComponent("outer/nested.txt")))

            let destination = root.appendingPathComponent("destination")
            try await AsyncFileSystem.replaceWithSymlinkedDirectory(
                source: source, destination: destination)
            #expect(try await AsyncFileSystem.exists(destination))
            #expect(!(try await AsyncFileSystem.isDirectoryAndNotSymlink(destination)))
            #expect(
                try await AsyncFileSystem.exists(destination.appendingPathComponent("file.txt")))
            let data = try await AsyncFileSystem.readData(
                from: destination.appendingPathComponent("file.txt"))
            #expect(String(data: data, encoding: .utf8) == "value")
            #expect(
                !(try await AsyncFileSystem.isDirectoryAndNotSymlink(
                    destination.appendingPathComponent("file.txt"))))
        }
    }

    @Test
    func replaceWithCopiedDirectoryMaterializesDirectory() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("downloads/example/package/1.0.0")
            try await AsyncFileSystem.createDirectory(at: source, withIntermediateDirectories: true)
            try await AsyncFileSystem.atomicWrite(
                "manifest", to: source.appendingPathComponent("Package.swift"))

            try await AsyncFileSystem.replaceWithCopiedDirectory(
                source: source, destination: destination)
            try await AsyncFileSystem.removeItem(at: source)

            #expect(try await AsyncFileSystem.isDirectoryAndNotSymlink(destination))
            let data = try await AsyncFileSystem.readData(
                from: destination.appendingPathComponent("Package.swift"))
            #expect(String(data: data, encoding: .utf8) == "manifest")
        }
    }

    @Test
    func temporaryDirectoryAndFileSafeNameUseScopedPaths() async throws {
        try await withTemporaryDirectory { root in
            let temp = try await AsyncFileSystem.temporaryDirectory(in: root)

            #expect(temp.path.hasPrefix(root.path))
            #expect(try await AsyncFileSystem.exists(temp))
            #expect(SafeFileName.make("a/b:c") == "a_b_c")
        }
    }
}
