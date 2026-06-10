import Testing
@testable import SwifterPMCore

struct SemVerTests {
    @Test
    func semanticVersionsIgnoreBuildMetadataAndOrderPrereleasesBeforeReleases() throws {
        #expect(try SemVer("1.2.3+build.7").description == "1.2.3")
        #expect(try SemVer("1.2.3-alpha") < SemVer("1.2.3"))
        #expect(try SemVer("1.2.3") < SemVer("1.2.4"))
    }

    @Test
    func semanticVersionsAcceptAbbreviatedCoresAndRejectNonNumericOnes() throws {
        // SwiftPM-compatible: shorter cores normalize zero-extended.
        #expect(try SemVer("1.2").description == "1.2.0")
        #expect(try SemVer("1").description == "1.0.0")
        #expect(try SemVer("0.4") == SemVer("0.4.0"))

        #expect(throws: (any Error).self) {
            try SemVer("one.two.three")
        }
        #expect(throws: (any Error).self) {
            try SemVer("1.2.3.4")
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
