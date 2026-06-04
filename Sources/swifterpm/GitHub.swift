import Foundation

struct GitHubRepo: Sendable {
    let owner: String
    let repo: String

    init(location: String) throws {
        let normalized = location.hasPrefix("git@github.com:")
            ? location.replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
            : location
        guard let url = URL(string: normalized), url.host == "github.com" else {
            throw fail("not a GitHub URL")
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            throw fail("GitHub URL has no owner or repo")
        }
        owner = parts[0]
        repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
    }
}

func githubToken() -> String? {
    let env = ProcessInfo.processInfo.environment
    if let token = env["GITHUB_TOKEN"] ?? env["GH_TOKEN"], !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return token
    }
    guard let output = try? commandOutput("gh", ["auth", "token"]) else {
        return nil
    }
    let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
}
