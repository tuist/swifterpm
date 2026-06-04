import Testing

struct SemVerTests {
    @Test
    func semanticVersionsIgnoreBuildMetadataAndOrderPrereleasesBeforeReleases() throws {
        #expect(try SemVer("1.2.3+build.7").description == "1.2.3")
        #expect(try SemVer("1.2.3-alpha") < SemVer("1.2.3"))
        #expect(try SemVer("1.2.3") < SemVer("1.2.4"))
    }

    @Test
    func semanticVersionsRejectInvalidCores() {
        #expect(throws: (any Error).self) {
            try SemVer("1.2")
        }
        #expect(throws: (any Error).self) {
            try SemVer("one.two.three")
        }
    }

    @Test
    func versionRangesMatchExactAndOpenRanges() throws {
        let exact = try VersionRange.singleton(SemVer("1.2.3"))
        #expect(try exact.contains(SemVer("1.2.3")))
        #expect(try !exact.contains(SemVer("1.2.4")))

        let range = try VersionRange.between(SemVer("1.0.0"), SemVer("2.0.0"))
        #expect(try range.contains(SemVer("1.5.0")))
        #expect(try !range.contains(SemVer("2.0.0")))
    }
}
