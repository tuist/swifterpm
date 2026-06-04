import Testing

struct GitHubTests {
    @Test
    func parsesHTTPSGitHubLocations() throws {
        let repo = try GitHubRepo(location: "https://github.com/tuist/swifterpm.git")

        #expect(repo.owner == "tuist")
        #expect(repo.repo == "swifterpm")
    }

    @Test
    func parsesSSHGitHubLocations() throws {
        let repo = try GitHubRepo(location: "git@github.com:tuist/swifterpm.git")

        #expect(repo.owner == "tuist")
        #expect(repo.repo == "swifterpm")
    }

    @Test
    func rejectsNonGitHubLocations() {
        #expect(throws: (any Error).self) {
            try GitHubRepo(location: "https://gitlab.com/tuist/swifterpm")
        }
    }
}
