import Foundation

enum ManifestDependencyKind: Hashable, Sendable {
    case sourceControl
    case registry
}

struct ManifestDependency: Sendable {
    let identity: String
    let kind: ManifestDependencyKind
    let location: String
    let requirement: Requirement
}

struct ManifestFileSystemDependency: Sendable {
    let identity: String
    let name: String
    let path: String
}

enum Requirement: Sendable {
    case exact(SemVer)
    case range(lower: SemVer, upper: SemVer)
    case revision(String)
    case branch(String)
}

let manifestCacheFile = ".swifterpm-manifest.json"

func dumpPackage(packageDir: URL, disableSandbox: Bool) throws -> Any {
    let data = try dumpPackageJSON(packageDir: packageDir, disableSandbox: disableSandbox)
    return try JSONSerialization.jsonObject(with: data)
}

func dumpPackageJSON(packageDir: URL, disableSandbox: Bool) throws -> Data {
    if let cached = try readCachedManifest(packageDir: packageDir) {
        return cached
    }

    var args = ["package"]
    if disableSandbox {
        args.append("--disable-sandbox")
    }
    args.append("dump-package")
    let result = try runCommand("/usr/bin/swift", args, workingDirectory: packageDir)
    try? atomicWrite(result.stdout, to: packageDir.appendingPathComponent(manifestCacheFile))
    return result.stdout
}

private func readCachedManifest(packageDir: URL) throws -> Data? {
    let cache = packageDir.appendingPathComponent(manifestCacheFile)
    let manifest = packageDir.appendingPathComponent("Package.swift")
    guard FileManager.default.fileExists(atPath: cache.path) else { return nil }
    let cacheAttrs = try FileManager.default.attributesOfItem(atPath: cache.path)
    let manifestAttrs = try FileManager.default.attributesOfItem(atPath: manifest.path)
    guard let cacheDate = cacheAttrs[.modificationDate] as? Date,
          let manifestDate = manifestAttrs[.modificationDate] as? Date,
          cacheDate >= manifestDate
    else {
        return nil
    }
    return try Data(contentsOf: cache)
}

func parseManifestDependencies(_ manifest: Any) throws -> [ManifestDependency] {
    var dependencies: [ManifestDependency] = []
    guard let root = manifest as? [String: Any],
          let items = root["dependencies"] as? [[String: Any]]
    else {
        return dependencies
    }

    for item in items {
        if let sourceControl = item["sourceControl"] as? [[String: Any]] {
            for dependency in sourceControl {
                guard let identity = dependency["identity"] as? String else {
                    throw ToolError.message("sourceControl dependency is missing identity")
                }
                guard let location = parseSourceControlLocation(dependency) else {
                    throw ToolError.message("\(identity) is missing source-control location")
                }
                guard let requirementJSON = dependency["requirement"] else {
                    throw ToolError.message("\(identity) is missing requirement")
                }
                dependencies.append(ManifestDependency(
                    identity: identity,
                    kind: .sourceControl,
                    location: location,
                    requirement: try parseRequirement(requirementJSON)
                ))
            }
        }

        if let registry = item["registry"] as? [[String: Any]] {
            for dependency in registry {
                guard let identity = dependency["identity"] as? String else {
                    throw ToolError.message("registry dependency is missing identity")
                }
                guard let requirementJSON = dependency["requirement"] else {
                    throw ToolError.message("\(identity) is missing requirement")
                }
                dependencies.append(ManifestDependency(
                    identity: identity,
                    kind: .registry,
                    location: identity,
                    requirement: try parseRequirement(requirementJSON)
                ))
            }
        }
    }

    return dependencies
}

private func parseSourceControlLocation(_ dependency: [String: Any]) -> String? {
    guard let location = dependency["location"] as? [String: Any] else {
        return nil
    }
    if let remote = location["remote"] as? [[String: Any]],
       let first = remote.first,
       let url = first["urlString"] as? String
    {
        return url
    }
    if let local = location["local"] as? [String],
       let first = local.first
    {
        return first
    }
    return nil
}

func parseRequiredManifestDependencies(_ manifest: Any) throws -> [ManifestDependency] {
    let dependencies = try parseManifestDependencies(manifest)
    let references = activeDependencyReferences(manifest)
    if references.isEmpty {
        return []
    }
    return dependencies.filter { dependency in
        dependencyReferenceNames(dependency).contains { references.contains($0) }
    }
}

private func activeDependencyReferences(_ manifest: Any) -> Set<String> {
    guard let root = manifest as? [String: Any],
          let targets = root["targets"] as? [[String: Any]]
    else {
        return []
    }

    let targetNames = Set(targets.compactMap { $0["name"] as? String })
    var pendingTargets: [String] = []
    if let products = root["products"] as? [[String: Any]] {
        for product in products {
            if let targets = product["targets"] as? [String] {
                pendingTargets.append(contentsOf: targets)
            }
        }
    }
    for target in targets where target["type"] as? String == "test" {
        if let name = target["name"] as? String {
            pendingTargets.append(name)
        }
    }

    var references = Set<String>()
    var visitedTargets = Set<String>()

    while let targetName = pendingTargets.popLast() {
        guard visitedTargets.insert(targetName).inserted,
              let target = targets.first(where: { $0["name"] as? String == targetName }),
              let dependencies = target["dependencies"] as? [[String: Any]]
        else {
            continue
        }

        for dependency in dependencies {
            if let product = dependency["product"] as? [Any] {
                let productName = product.first as? String
                let packageName = product.count > 1 ? product[1] as? String : nil
                if let name = packageName ?? productName {
                    references.insert(normalizeDependencyReference(name))
                }
            }
            if let byName = dependency["byName"] as? [Any],
               let name = byName.first as? String
            {
                if targetNames.contains(name) {
                    pendingTargets.append(name)
                } else {
                    references.insert(normalizeDependencyReference(name))
                }
            }
        }
    }

    return references
}

private func dependencyReferenceNames(_ dependency: ManifestDependency) -> Set<String> {
    var names = Set<String>()
    names.insert(normalizeDependencyReference(dependency.identity))
    if let suffix = dependency.identity.split(separator: ".").last {
        names.insert(normalizeDependencyReference(String(suffix)))
    }
    if dependency.kind == .sourceControl,
       let name = dependency.location.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .replacingOccurrences(of: ".git", with: "")
        .split(separator: "/")
        .last
    {
        names.insert(normalizeDependencyReference(String(name)))
    }
    return names
}

private func normalizeDependencyReference(_ name: String) -> String {
    let value = name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    return value.lowercased()
}

func parseManifestFileSystemDependencies(_ manifest: Any) throws -> [ManifestFileSystemDependency] {
    guard let root = manifest as? [String: Any],
          let items = root["dependencies"] as? [[String: Any]]
    else {
        return []
    }

    var dependencies: [ManifestFileSystemDependency] = []
    for item in items {
        guard let fileSystem = item["fileSystem"] as? [[String: Any]] else { continue }
        for dependency in fileSystem {
            guard let identity = dependency["identity"] as? String else {
                throw ToolError.message("fileSystem dependency is missing identity")
            }
            guard let path = dependency["path"] as? String else {
                throw ToolError.message("\(identity) is missing path")
            }
            dependencies.append(ManifestFileSystemDependency(
                identity: identity,
                name: dependency["nameForTargetDependencyResolutionOnly"] as? String ?? identity,
                path: path
            ))
        }
    }
    return dependencies
}

func parseRequirement(_ requirement: Any) throws -> Requirement {
    guard let requirement = requirement as? [String: Any] else {
        throw ToolError.message("unsupported requirement shape: \(requirement)")
    }
    if let exact = requirement["exact"] as? [String], let value = exact.first {
        return .exact(try SemVer(value))
    }
    if let range = requirement["range"] as? [[String: Any]], let first = range.first {
        guard let lower = first["lowerBound"] as? String,
              let upper = first["upperBound"] as? String
        else {
            throw ToolError.message("range is missing lowerBound or upperBound")
        }
        return .range(lower: try SemVer(lower), upper: try SemVer(upper))
    }
    if let revision = requirement["revision"] as? [String], let value = revision.first {
        return .revision(value)
    }
    if let branch = requirement["branch"] as? [String], let value = branch.first {
        return .branch(value)
    }
    throw ToolError.message("unsupported requirement shape: \(requirement)")
}

func versionRange(for requirement: Requirement) -> VersionRange? {
    switch requirement {
    case let .exact(version):
        return .singleton(version)
    case let .range(lower, upper):
        return .between(lower, upper)
    case .revision, .branch:
        return nil
    }
}
