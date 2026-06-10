import Foundation

struct SemVer: Hashable, Comparable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String

    init(_ string: String) throws {
        let withoutBuild = string.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".")
        // SwiftPM tolerates 1- and 2-component version tags (e.g. swift-subprocess ships `0.4`)
        // and treats missing components as zero. Mirror that to stay compatible with packages
        // that pin or expose abbreviated tags.
        guard (1...3).contains(core.count),
              let major = Int(core[0]),
              core.count < 2 || Int(core[1]) != nil,
              core.count < 3 || Int(core[2]) != nil
        else {
            throw ToolError.message("invalid semantic version: \(string)")
        }
        self.major = major
        self.minor = core.count >= 2 ? Int(core[1])! : 0
        self.patch = core.count >= 3 ? Int(core[2])! : 0
        self.prerelease = parts.count > 1 ? String(parts[1]) : ""
    }

    init(major: Int, minor: Int, patch: Int, prerelease: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : "\(core)-\(prerelease)"
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty && !rhs.prerelease.isEmpty { return false }
        if !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return true }
        return lhs.prerelease < rhs.prerelease
    }
}

struct VersionRange: Equatable, Sendable {
    let lower: SemVer
    let upper: SemVer
    let exact: Bool

    static func singleton(_ version: SemVer) -> VersionRange {
        VersionRange(lower: version, upper: version, exact: true)
    }

    static func between(_ lower: SemVer, _ upper: SemVer) -> VersionRange {
        VersionRange(lower: lower, upper: upper, exact: false)
    }

    func contains(_ version: SemVer) -> Bool {
        if exact {
            return version == lower
        }
        return version >= lower && version < upper
    }
}
