import Testing

struct CLITests {
    @Test
    func resolveParsesGlobalAndCommandOptions() throws {
        let cli = try CLIParser.parse([
            "--package-path", "/tmp/package",
            "--cache-path", "/tmp/cache",
            "--scratch-path", "/tmp/scratch",
            "--disable-sandbox",
            "--default-registry-url", "https://registry.example.com",
            "-q",
            "resolve",
            "--package-dir", "/tmp/command-package",
            "--cache-dir", "/tmp/command-cache",
            "--write",
            "--print-only",
        ])

        #expect(cli.packagePath?.path == "/tmp/package")
        #expect(cli.cachePath?.path == "/tmp/cache")
        #expect(cli.scratchPath?.path == "/tmp/scratch")
        #expect(cli.disableSandbox)
        #expect(cli.quiet)
        #expect(cli.defaultRegistryURL == "https://registry.example.com")

        guard case .resolve(let options) = cli.command else {
            Issue.record("expected resolve command")
            return
        }
        #expect(options.packageDir.path == "/tmp/command-package")
        #expect(options.cacheDir?.path == "/tmp/command-cache")
        #expect(options.write)
        #expect(!options.restore)
        #expect(options.printOnly)
    }

    @Test
    func updateParsesPackageNamesAndFlags() throws {
        let cli = try CLIParser.parse([
            "--skip-update",
            "update",
            "foo",
            "bar",
            "--restore",
        ])

        #expect(cli.skipUpdate)
        guard case .update(let options) = cli.command else {
            Issue.record("expected update command")
            return
        }
        #expect(options.packageNames == ["foo", "bar"])
        #expect(options.restore)
    }

    @Test
    func restoreParsesDirectoryOptions() throws {
        let cli = try CLIParser.parse([
            "--build-path", "/tmp/build",
            "restore",
            "--package-dir", "/tmp/package",
            "--cache-dir", "/tmp/cache",
            "--scratch-dir", "/tmp/scratch",
        ])

        #expect(cli.buildPath?.path == "/tmp/build")
        guard case .restore(let options) = cli.command else {
            Issue.record("expected restore command")
            return
        }
        #expect(options.packageDir.path == "/tmp/package")
        #expect(options.cacheDir?.path == "/tmp/cache")
        #expect(options.scratchDir?.path == "/tmp/scratch")
    }

    @Test
    func commandSpecificUnknownOptionsAreRejected() {
        #expect(throws: (any Error).self) {
            try CLIParser.parse(["resolve", "--unknown-option"])
        }
    }
}
