import Foundation

func makeTemporaryDirectory() async throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("swifterpm-tests-\(UUID().uuidString)", isDirectory: true)
    try await AsyncFileSystem.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = try await makeTemporaryDirectory()
    do {
        let result = try await body(directory)
        try? await AsyncFileSystem.removeItem(at: directory)
        return result
    } catch {
        try? await AsyncFileSystem.removeItem(at: directory)
        throw error
    }
}

func writeCachedManifest(_ manifest: [String: Any], packageDir: URL) async throws {
    try await AsyncFileSystem.createDirectory(at: packageDir, withIntermediateDirectories: true)
    try await atomicWrite(
        """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(name: "Fixture")
    """,
        to: packageDir.appendingPathComponent("Package.swift")
    )
    try await atomicWrite(try prettyJSONData(manifest), to: packageDir.appendingPathComponent(manifestCacheFile))
}

func fixtureURL(_ components: String...) async throws -> URL {
    let relative = ["Tests", "swifterpmTests", "Fixtures"] + components
    let env = ProcessInfo.processInfo.environment
    var candidates = [
        URL(fileURLWithPath: try await AsyncFileSystem.currentDirectoryPath())
            .appendingPathComponents(relative),
    ]

    if let testSrcDir = env["TEST_SRCDIR"] {
        let srcDir = URL(fileURLWithPath: testSrcDir)
        if let workspace = env["TEST_WORKSPACE"] {
            candidates.append(srcDir.appendingPathComponent(workspace).appendingPathComponents(relative))
        }
        candidates.append(srcDir.appendingPathComponents(relative))
        candidates.append(srcDir.appendingPathComponent("_main").appendingPathComponents(relative))
    }

    for candidate in candidates where (try await AsyncFileSystem.exists(candidate)) {
        return candidate
    }
    throw ToolError.message("fixture not found: \(components.joined(separator: "/"))")
}

func emptyManifest(name: String = "Fixture") -> [String: Any] {
    [
        "name": name,
        "dependencies": [],
        "products": [],
        "targets": [],
    ]
}
