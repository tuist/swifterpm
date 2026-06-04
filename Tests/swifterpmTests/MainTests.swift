import Testing

struct MainTests {
    @Test
    func executableMetadataMatchesCommandConfiguration() {
        #expect(swifterpmVersion == "0.1.0")
        #expect(SwifterPMCommand.configuration.commandName == "swifterpm")
        #expect(SwifterPMCommand.configuration.version == swifterpmVersion)
    }
}
