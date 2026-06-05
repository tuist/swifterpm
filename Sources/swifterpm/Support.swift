import CryptoKit
import Foundation
import Subprocess

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

enum ToolError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message):
            return message
        }
    }
}

enum SystemProcess {
    struct Result {
        let stdout: Data
        let stderr: Data

        var stdoutString: String {
            String(data: stdout, encoding: .utf8) ?? ""
        }

        var stderrString: String {
            String(data: stderr, encoding: .utf8) ?? ""
        }
    }

    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        outputLimit: Int = 64 * 1024 * 1024
    ) async throws -> Result {
        let result = try await Subprocess.run(
            subprocessExecutable(executable),
            arguments: Arguments(arguments),
            environment: subprocessEnvironment(environment),
            workingDirectory: workingDirectory.map { FilePath($0.path) },
            output: .data(limit: outputLimit),
            error: .data(limit: outputLimit)
        )

        guard result.terminationStatus.isSuccess else {
            let stderrText = String(data: result.standardError, encoding: .utf8) ?? ""
            let stdoutText = String(data: result.standardOutput, encoding: .utf8) ?? ""
            let message = stderrText.isEmpty ? stdoutText : stderrText
            throw ToolError.message(
                message.isEmpty ? result.terminationStatus.description : message)
        }

        return Result(stdout: result.standardOutput, stderr: result.standardError)
    }

    static func output(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        outputLimit: Int = 64 * 1024 * 1024
    ) async throws -> String {
        try await run(
            executable,
            arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            outputLimit: outputLimit
        ).stdoutString
    }

    private static func subprocessExecutable(_ executable: String) -> Executable {
        executable.contains("/") ? .path(FilePath(executable)) : .name(executable)
    }

    private static func subprocessEnvironment(_ environment: [String: String])
        -> Subprocess.Environment
    {
        guard !environment.isEmpty else { return .inherit }
        var overrides: [Subprocess.Environment.Key: String?] = [:]
        for (key, value) in environment {
            if let subprocessKey = Subprocess.Environment.Key(rawValue: key) {
                overrides[subprocessKey] = value
            }
        }
        return .inherit.updating(overrides)
    }
}

enum HTTPClient {
    static func data(url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
            !(200..<300).contains(httpResponse.statusCode)
        {
            throw ToolError.message("HTTP \(httpResponse.statusCode) for \(url.absoluteString)")
        }
        return data
    }

    static func download(url: URL, destination: URL, headers: [String: String] = [:]) async throws {
        let data = try await data(url: url, headers: headers)
        try await AsyncFileSystem.atomicWrite(data, to: destination)
    }
}

enum Hashing {
    static func stable(_ input: String) -> String {
        sha256Hex(Data(input.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func shortRevision(_ revision: String) -> String {
        String(revision.prefix(12))
    }
}

private let defaultParallelism = max(4, min(32, ProcessInfo.processInfo.activeProcessorCount * 4))

enum ConcurrentTasks {
    static func map<Element: Sendable, Output: Sendable>(
        _ elements: [Element],
        maxConcurrentTasks: Int = defaultParallelism,
        operation: @Sendable @escaping (Element) async throws -> Output
    ) async throws -> [Output] {
        guard !elements.isEmpty else { return [] }
        let limit = max(1, min(maxConcurrentTasks, elements.count))

        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var iterator = elements.enumerated().makeIterator()
            var activeTasks = 0
            var results = Array<Output?>(repeating: nil, count: elements.count)

            while activeTasks < limit, let (index, element) = iterator.next() {
                group.addTask {
                    (index, try await operation(element))
                }
                activeTasks += 1
            }

            while activeTasks > 0 {
                guard let (index, result) = try await group.next() else { break }
                activeTasks -= 1
                results[index] = result

                if let (index, element) = iterator.next() {
                    group.addTask {
                        (index, try await operation(element))
                    }
                    activeTasks += 1
                }
            }

            var ordered: [Output] = []
            ordered.reserveCapacity(elements.count)
            for result in results {
                guard let result else {
                    throw ToolError.message("concurrent task result missing")
                }
                ordered.append(result)
            }
            return ordered
        }
    }

    static func forEach<Element: Sendable>(
        _ elements: [Element],
        maxConcurrentTasks: Int = defaultParallelism,
        operation: @Sendable @escaping (Element) async throws -> Void
    ) async throws {
        _ =
            try await map(elements, maxConcurrentTasks: maxConcurrentTasks, operation: operation)
            as [Void]
    }
}

final class PathLock: @unchecked Sendable {
    private let fd: Int32

    init(path: URL) throws {
        fd = open(
            path.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH)
        if fd < 0 {
            throw ToolError.message("failed to open lock \(path.path)")
        }
        if flock(fd, LOCK_EX) != 0 {
            close(fd)
            throw ToolError.message("failed to lock \(path.path)")
        }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

extension PathLock {
    static func acquire(at path: URL) async throws -> PathLock {
        try await AsyncFileSystem.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try await Task.detached {
            try PathLock(path: path)
        }.value
    }
}

extension AsyncFileSystem {
    static func atomicWrite(_ data: Data, to url: URL) async throws {
        try await writeData(data, to: url)
    }

    static func atomicWrite(_ string: String, to url: URL) async throws {
        try await atomicWrite(Data(string.utf8), to: url)
    }

    static func removePath(_ url: URL) async throws {
        guard try await exists(url) else { return }
        try await removeItem(at: url)
    }

    static func replaceWithSymlinkedDirectory(source: URL, destination: URL) async throws {
        if try await exists(destination) {
            try await removePath(destination)
        }
        try await createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await createSymbolicLink(at: destination, withDestinationURL: source)
    }

    static func flattenSingleDirectory(_ url: URL) async throws {
        let entries = try await contentsOfDirectory(at: url)
        guard entries.count == 1 else { return }
        let nested = entries[0]
        guard try await isDirectoryAndNotSymlink(nested) else { return }

        let temp = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).flattening")
        if try await exists(temp) {
            try await removeItem(at: temp)
        }
        try await moveItem(at: nested, to: temp)
        try await removeItem(at: url)
        try await moveItem(at: temp, to: url)
    }

    static func temporaryDirectory(in parent: URL) async throws -> URL {
        try await createDirectory(at: parent, withIntermediateDirectories: true)
        let url = parent.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try await createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum JSONFormatter {
    static func prettyData(_ object: Any) throws -> Data {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return data + Data("\n".utf8)
    }
}

enum SafeFileName {
    static func make(_ name: String) -> String {
        String(
            name.map { character in
                if character.isASCII
                    && (character.isLetter || character.isNumber || character == "-"
                        || character == "_"
                        || character == ".")
                {
                    return character
                }
                return "_"
            })
    }
}

extension URL {
    func appendingPathComponents(_ components: [String]) -> URL {
        components.reduce(self) { partial, component in
            partial.appendingPathComponent(component)
        }
    }
}
