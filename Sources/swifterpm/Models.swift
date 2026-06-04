import Foundation

struct ResolvedPins: Codable, Sendable {
    var originHash: String?
    var pins: [ResolvedPin]
    var version: Int
}

struct ResolvedPin: Codable, Equatable, Sendable {
    var identity: String
    var kind: String
    var location: String
    var state: ResolvedState

    func revision() throws -> String {
        guard let revision = state.revision else {
            throw fail("\(identity) does not have a source-control revision")
        }
        return revision
    }

    func versionString() throws -> String {
        guard let version = state.version else {
            throw fail("\(identity) does not have a resolved version")
        }
        return version
    }
}

struct ResolvedState: Codable, Equatable, Sendable {
    var branch: String?
    var revision: String?
    var version: String?
}

func readResolvedFile(packageDir: URL) throws -> ResolvedPins {
    let data = try Data(contentsOf: packageDir.appendingPathComponent("Package.resolved"))
    return try JSONDecoder().decode(ResolvedPins.self, from: data)
}

func writeResolvedFile(packageDir: URL, resolved: ResolvedPins) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(resolved) + Data("\n".utf8)
    try atomicWrite(data, to: packageDir.appendingPathComponent("Package.resolved"))
}

func printResolution(_ resolved: ResolvedPins) {
    for pin in resolved.pins {
        if isRegistryKind(pin.kind) {
            print("\(pin.identity) \(pin.state.version ?? "<unknown>") registry")
        } else if let version = pin.state.version {
            print("\(pin.identity) \(version) \(pin.state.revision ?? "<unknown>") \(pin.location)")
        } else {
            print("\(pin.identity) \(pin.state.revision ?? "<unknown>") \(pin.location)")
        }
    }
}

func isSourceControlKind(_ kind: String) -> Bool {
    kind == "remoteSourceControl" || kind == "localSourceControl" || kind == "sourceControl"
}

func isRegistryKind(_ kind: String) -> Bool {
    kind == "registry"
}

func checkoutDirectoryName(_ pin: ResolvedPin) -> String {
    let trimmed = pin.location.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let withoutGit = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed
    return withoutGit.split(separator: "/").last.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? pin.identity
}

func registryIdentityParts(_ identity: String) throws -> (String, String) {
    let parts = identity.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2 else {
        throw fail("\(identity) is not a scoped registry package identity")
    }
    return (parts[0], parts[1])
}

func registryDownloadSubpath(_ pin: ResolvedPin) throws -> String {
    let (scope, name) = try registryIdentityParts(pin.identity)
    return "\(scope)/\(name)/\(try pin.versionString())"
}
