import Testing

struct RemoteTests {
    @Test
    func parseSwiftTagVersionAcceptsPlainAndPrefixedVersions() {
        #expect(parseSwiftTagVersion("1.2.3")?.description == "1.2.3")
        #expect(parseSwiftTagVersion("v1.2.3")?.description == "1.2.3")
        #expect(parseSwiftTagVersion("1.2.3-alpha.1")?.description == "1.2.3-alpha.1")
    }

    @Test
    func parseSwiftTagVersionRejectsNonSemanticTags() {
        #expect(parseSwiftTagVersion("release-1.2.3") == nil)
        #expect(parseSwiftTagVersion("main") == nil)
    }

    @Test
    func remoteVersionSemverIgnoresInvalidVersions() {
        #expect(RemoteVersion(version: "1.2.3", revision: "abcdef").semver?.description == "1.2.3")
        #expect(RemoteVersion(version: "nightly", revision: "abcdef").semver == nil)
    }
}
