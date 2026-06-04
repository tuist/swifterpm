import CryptoKit
import Foundation

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
        case let .message(message):
            return message
        }
    }
}

struct CommandResult {
    let stdout: Data
    let stderr: Data

    var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

private final class PipeDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.withLock {
            data = value
        }
    }

    func get() -> Data {
        lock.withLock {
            data
        }
    }
}

@discardableResult
func runCommand(
    _ executable: String,
    _ arguments: [String],
    workingDirectory: URL? = nil,
    environment: [String: String] = [:]
) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let workingDirectory {
        process.currentDirectoryURL = workingDirectory
    }
    if !environment.isEmpty {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            merged[key] = value
        }
        process.environment = merged
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let stdoutBox = PipeDataBox()
    let stderrBox = PipeDataBox()
    let readGroup = DispatchGroup()

    readGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        readGroup.leave()
    }

    readGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        readGroup.leave()
    }

    do {
        try process.run()
    } catch {
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        readGroup.wait()
        throw error
    }

    process.waitUntilExit()
    readGroup.wait()

    let stdout = stdoutBox.get()
    let stderr = stderrBox.get()

    if process.terminationStatus != 0 {
        let stderrText = String(data: stderr, encoding: .utf8) ?? ""
        let stdoutText = String(data: stdout, encoding: .utf8) ?? ""
        throw ToolError.message(stderrText.isEmpty ? stdoutText : stderrText)
    }
    return CommandResult(stdout: stdout, stderr: stderr)
}

func commandOutput(
    _ executable: String,
    _ arguments: [String],
    workingDirectory: URL? = nil,
    environment: [String: String] = [:]
) throws -> String {
    try runCommand(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment
    ).stdoutString
}

@discardableResult
func runCommandAsync(
    _ executable: String,
    _ arguments: [String],
    workingDirectory: URL? = nil,
    environment: [String: String] = [:]
) async throws -> CommandResult {
    try await Task.detached {
        try runCommand(
            executable,
            arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }.value
}

func commandOutputAsync(
    _ executable: String,
    _ arguments: [String],
    workingDirectory: URL? = nil,
    environment: [String: String] = [:]
) async throws -> String {
    try await runCommandAsync(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment
    ).stdoutString
}

func httpData(url: URL, headers: [String: String] = [:]) async throws -> Data {
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

func httpDownload(url: URL, destination: URL, headers: [String: String] = [:]) async throws {
    let data = try await httpData(url: url, headers: headers)
    try atomicWrite(data, to: destination)
}

func stableHash(_ input: String) -> String {
    sha256Hex(Data(input.utf8))
}

func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

func shortRevision(_ revision: String) -> String {
    String(revision.prefix(12))
}

func atomicWrite(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
}

func atomicWrite(_ string: String, to url: URL) throws {
    try atomicWrite(Data(string.utf8), to: url)
}

final class PathLock {
    private let fd: Int32

    init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        fd = open(path.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH)
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

func pathExistsOrIsSymlink(_ url: URL) -> Bool {
    var statBuffer = stat()
    return lstat(url.path, &statBuffer) == 0
}

func isDirectoryAndNotSymlink(_ url: URL) -> Bool {
    var statBuffer = stat()
    guard lstat(url.path, &statBuffer) == 0 else { return false }
    let fileType = statBuffer.st_mode & S_IFMT
    return fileType == S_IFDIR
}

func removePath(_ url: URL) throws {
    guard pathExistsOrIsSymlink(url) else { return }
    if isDirectoryAndNotSymlink(url) {
        try FileManager.default.removeItem(at: url)
    } else {
        try FileManager.default.removeItem(at: url)
    }
}

func replaceWithSymlinkedDirectoryContents(source: URL, destination: URL) throws {
    if pathExistsOrIsSymlink(destination) {
        try removePath(destination)
    }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let entries = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
    for entry in entries {
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent(entry.lastPathComponent),
            withDestinationURL: entry
        )
    }
}

func flattenSingleDirectory(_ url: URL) throws {
    let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
    guard entries.count == 1 else { return }
    let nested = entries[0]
    let values = try nested.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory == true else { return }

    let temp = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).flattening")
    if FileManager.default.fileExists(atPath: temp.path) {
        try FileManager.default.removeItem(at: temp)
    }
    try FileManager.default.moveItem(at: nested, to: temp)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: temp, to: url)
}

func temporaryDirectory(in parent: URL) throws -> URL {
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let url = parent.appendingPathComponent(".tmp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func prettyJSONData(_ object: Any) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    return data + Data("\n".utf8)
}

func fileSafeName(_ name: String) -> String {
    String(name.map { character in
        if character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_" || character == ".") {
            return character
        }
        return "_"
    })
}

extension URL {
    func appendingPathComponents(_ components: [String]) -> URL {
        components.reduce(self) { partial, component in
            partial.appendingPathComponent(component)
        }
    }
}
