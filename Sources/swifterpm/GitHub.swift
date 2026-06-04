import Foundation

struct GitHubRepo: Sendable {
    let owner: String
    let repo: String

    init(location: String) throws {
        let normalized = location.hasPrefix("git@github.com:")
            ? location.replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
            : location
        guard let url = URL(string: normalized), url.host == "github.com" else {
            throw ToolError.message("not a GitHub URL")
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            throw ToolError.message("GitHub URL has no owner or repo")
        }
        owner = parts[0]
        repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
    }
}

private actor GitHubTokenCache {
    private var loaded = false
    private var cachedToken: String?

    func token() async -> String? {
        if loaded {
            return cachedToken
        }
        loaded = true

        let env = ProcessInfo.processInfo.environment
        if let token = env["GITHUB_TOKEN"] ?? env["GH_TOKEN"],
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            cachedToken = token
            return token
        }

        guard let output = try? await commandOutputAsync("/usr/bin/env", ["gh", "auth", "token"]) else {
            return nil
        }
        let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedToken = token.isEmpty ? nil : token
        return cachedToken
    }
}

private let githubTokenCache = GitHubTokenCache()

func githubToken() async -> String? {
    await githubTokenCache.token()
}

func hasGitHubSession() async -> Bool {
    await githubToken() != nil
}

func sourceControlFetchLocations(_ location: String) -> [String] {
    var locations = [location]
    if let repo = try? GitHubRepo(location: location) {
        let ssh = "git@github.com:\(repo.owner)/\(repo.repo).git"
        if !locations.contains(ssh) {
            locations.append(ssh)
        }
    }
    return locations
}
