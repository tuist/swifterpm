import Foundation

func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("swifterpm-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func writeCachedManifest(_ manifest: [String: Any], packageDir: URL) throws {
    try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
    try """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(name: "Fixture")
    """.write(to: packageDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try atomicWrite(try prettyJSONData(manifest), to: packageDir.appendingPathComponent(manifestCacheFile))
}

func emptyManifest(name: String = "Fixture") -> [String: Any] {
    [
        "name": name,
        "dependencies": [],
        "products": [],
        "targets": [],
    ]
}
