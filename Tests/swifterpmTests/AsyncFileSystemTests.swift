import Foundation
import Testing
@testable import SwifterPMCore

struct AsyncFileSystemTests {
    @Test
    func readsWritesListsAndRemovesFilesWithNIOFileSystem() async throws {
        try await withTemporaryDirectory { root in
            let file = root.appendingPathComponent("nested/file.txt")
            try await AsyncFileSystem.writeData(Data("hello".utf8), to: file)

            #expect(try await AsyncFileSystem.exists(file))
            #expect(try await AsyncFileSystem.isRegularFile(file))
            #expect(String(data: try await AsyncFileSystem.readData(from: file), encoding: .utf8) == "hello")
            #expect(try await AsyncFileSystem.modificationDate(file) != nil)

            let entries = try await AsyncFileSystem.contentsOfDirectory(at: file.deletingLastPathComponent())
            #expect(Set(entries.map(\.lastPathComponent)) == ["file.txt"])

            try await AsyncFileSystem.removeItem(at: file)
            #expect(!(try await AsyncFileSystem.exists(file)))
        }
    }

    @Test
    func createDirectoryWithIntermediatesIsRaceSafeAcrossConcurrentTasks() async throws {
        try await withTemporaryDirectory { root in
            let shared = root.appendingPathComponent("a/b/c/d")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<32 {
                    let target = shared.appendingPathComponent("leaf-\(index)")
                    group.addTask {
                        try await AsyncFileSystem.createDirectory(
                            at: target.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                    }
                }
                try await group.waitForAll()
            }
            #expect(try await AsyncFileSystem.isDirectory(shared))
        }
    }

    @Test
    func createsSymlinksAndReportsCurrentDirectory() async throws {
        try await withTemporaryDirectory { root in
            let target = root.appendingPathComponent("target.txt")
            let link = root.appendingPathComponent("link.txt")
            let targetDirectory = root.appendingPathComponent("target-directory")
            let directoryLink = root.appendingPathComponent("directory-link")
            try await AsyncFileSystem.writeData(Data("target".utf8), to: target)
            try await AsyncFileSystem.createDirectory(
                at: targetDirectory, withIntermediateDirectories: true)
            try await AsyncFileSystem.createSymbolicLink(at: link, withDestinationURL: target)
            try await AsyncFileSystem.createSymbolicLink(
                at: directoryLink, withDestinationURL: targetDirectory)

            #expect(try await AsyncFileSystem.exists(link))
            #expect(!(try await AsyncFileSystem.isDirectoryAndNotSymlink(link)))
            #expect(try await AsyncFileSystem.isDirectory(directoryLink))
            #expect(!(try await AsyncFileSystem.isDirectoryAndNotSymlink(directoryLink)))
            #expect(!(try await AsyncFileSystem.currentDirectoryPath()).isEmpty)
        }
    }
}
