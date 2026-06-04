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
            throw ToolError.message("\(identity) does not have a source-control revision")
        }
        return revision
    }

    func versionString() throws -> String {
        guard let version = state.version else {
            throw ToolError.message("\(identity) does not have a resolved version")
        }
        return version
    }
}

struct ResolvedState: Codable, Equatable, Sendable {
    var branch: String?
    var revision: String?
    var version: String?
}

enum ResolvedFile {
    static func read(packageDir: URL) async throws -> ResolvedPins {
        let data = try await AsyncFileSystem.readData(
            from: packageDir.appendingPathComponent("Package.resolved"))
        return try JSONDecoder().decode(ResolvedPins.self, from: data)
    }

    static func write(packageDir: URL, resolved: ResolvedPins) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(resolved) + Data("\n".utf8)
        try await AsyncFileSystem.atomicWrite(
            data, to: packageDir.appendingPathComponent("Package.resolved"))
    }

    static func print(_ resolved: ResolvedPins) {
        for pin in resolved.pins {
            if PinKind.isRegistry(pin.kind) {
                Swift.print("\(pin.identity) \(pin.state.version ?? "<unknown>") registry")
            } else if let version = pin.state.version {
                Swift.print(
                    "\(pin.identity) \(version) \(pin.state.revision ?? "<unknown>") \(pin.location)"
                )
            } else {
                Swift.print("\(pin.identity) \(pin.state.revision ?? "<unknown>") \(pin.location)")
            }
        }
    }
}

enum PinKind {
    static func isSourceControl(_ kind: String) -> Bool {
        kind == "remoteSourceControl" || kind == "localSourceControl" || kind == "sourceControl"
    }

    static func isRegistry(_ kind: String) -> Bool {
        kind == "registry"
    }

    static func checkoutDirectoryName(_ pin: ResolvedPin) -> String {
        let trimmed = pin.location.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let withoutGit = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed
        return withoutGit.split(separator: "/").last.map(String.init).flatMap {
            $0.isEmpty ? nil : $0
        }
            ?? pin.identity
    }

    static func registryIdentityParts(_ identity: String) throws -> (String, String) {
        let parts = identity.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw ToolError.message("\(identity) is not a scoped registry package identity")
        }
        return (parts[0], parts[1])
    }

    static func registryDownloadSubpath(_ pin: ResolvedPin) throws -> String {
        let (scope, name) = try PinKind.registryIdentityParts(pin.identity)
        return "\(scope)/\(name)/\(try pin.versionString())"
    }
}
