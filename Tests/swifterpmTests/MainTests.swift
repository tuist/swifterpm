import Testing
@testable import SwifterPMCore

struct MainTests {
    @Test
    func executableMetadataMatchesCommandConfiguration() {
        #expect(swifterpmVersion == "0.8.1")
        #expect(SwifterPMCommand.configuration.commandName == "swifterpm")
        #expect(SwifterPMCommand.configuration.version == swifterpmVersion)
    }
}
