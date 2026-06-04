import Testing

struct RemoteTests {
    @Test
    func parseSwiftTagVersionAcceptsPlainAndPrefixedVersions() {
        #expect(RemoteMetadata.parseSwiftTagVersion("1.2.3")?.description == "1.2.3")
        #expect(RemoteMetadata.parseSwiftTagVersion("v1.2.3")?.description == "1.2.3")
        #expect(
            RemoteMetadata.parseSwiftTagVersion("1.2.3-alpha.1")?.description == "1.2.3-alpha.1")
    }

    @Test
    func parseSwiftTagVersionRejectsNonSemanticTags() {
        #expect(RemoteMetadata.parseSwiftTagVersion("release-1.2.3") == nil)
        #expect(RemoteMetadata.parseSwiftTagVersion("main") == nil)
    }

    @Test
    func remoteVersionSemverIgnoresInvalidVersions() {
        #expect(RemoteVersion(version: "1.2.3", revision: "abcdef").semver?.description == "1.2.3")
        #expect(RemoteVersion(version: "nightly", revision: "abcdef").semver == nil)
    }
}
