import Foundation
import Testing

struct AsyncFileSystemTests {
    @Test
    func readsWritesListsAndRemovesFilesWithoutFileManager() async throws {
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
    func createsSymlinksAndReportsCurrentDirectory() async throws {
        try await withTemporaryDirectory { root in
            let target = root.appendingPathComponent("target.txt")
            let link = root.appendingPathComponent("link.txt")
            try await AsyncFileSystem.writeData(Data("target".utf8), to: target)
            try await AsyncFileSystem.createSymbolicLink(at: link, withDestinationURL: target)

            #expect(try await AsyncFileSystem.exists(link))
            #expect(!(try await AsyncFileSystem.isDirectoryAndNotSymlink(link)))
            #expect(!(try await AsyncFileSystem.currentDirectoryPath()).isEmpty)
        }
    }
}
