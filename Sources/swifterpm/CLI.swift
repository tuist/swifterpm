import ArgumentParser
import Foundation

let swifterpmVersion = "0.1.0"

struct CLI {
    var chdir: URL?
    var packagePath: URL?
    var cachePath: URL?
    var scratchPath: URL?
    var buildPath: URL?
    var configPath: URL?
    var securityPath: URL?
    var disableSandbox = false
    var enableDependencyCache = false
    var disableDependencyCache = false
    var skipUpdate = false
    var forceResolvedVersions = false
    var disableAutomaticResolution = false
    var onlyUseVersionsFromResolvedFile = false
    var replaceSCMWithRegistry = false
    var useRegistryIdentityForSCM = false
    var defaultRegistryURL: String?
    var disableSCMToRegistryTransformation = false
    var quiet = false
    var disablePackageInfoCache = false
    var packageInfoCachePath: URL?
    var command: Command

    enum Command {
        case resolve(ResolveOptions)
        case update(UpdateOptions)
        case restore(RestoreOptions)
    }

    struct ResolveOptions {
        var packageName: String?
        var version: String?
        var branch: String?
        var revision: String?
        var packageDir = URL(fileURLWithPath: ".")
        var cacheDir: URL?
        var write = false
        var restore = false
        var printOnly = false
    }

    struct UpdateOptions {
        var packageNames: [String] = []
        var packageDir = URL(fileURLWithPath: ".")
        var cacheDir: URL?
        var write = false
        var restore = false
        var printOnly = false
    }

    struct RestoreOptions {
        var packageDir = URL(fileURLWithPath: ".")
        var cacheDir: URL?
        var scratchDir: URL?
    }
}

enum CLIAction: String, ExpressibleByArgument {
    case resolve
    case update
    case restore
}

struct SwifterPMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swifterpm",
        abstract: "Resolve and restore Swift package dependencies.",
        version: swifterpmVersion
    )

    @Option(name: .customLong("chdir"))
    var chdir: String?

    @Option(name: .customLong("package-path"))
    var packagePath: String?

    @Option(name: .customLong("cache-path"))
    var cachePath: String?

    @Option(name: .customLong("scratch-path"))
    var scratchPath: String?

    @Option(name: .customLong("build-path"))
    var buildPath: String?

    @Option(name: .customLong("config-path"))
    var configPath: String?

    @Option(name: .customLong("security-path"))
    var securityPath: String?

    @Flag(name: .customLong("disable-sandbox"))
    var disableSandbox = false

    @Flag(name: .customLong("enable-dependency-cache"))
    var enableDependencyCache = false

    @Flag(name: .customLong("disable-dependency-cache"))
    var disableDependencyCache = false

    @Flag(name: .customLong("skip-update"))
    var skipUpdate = false

    @Flag(name: .customLong("force-resolved-versions"))
    var forceResolvedVersions = false

    @Flag(name: .customLong("disable-automatic-resolution"))
    var disableAutomaticResolution = false

    @Flag(name: .customLong("only-use-versions-from-resolved-file"))
    var onlyUseVersionsFromResolvedFile = false

    @Flag(name: .customLong("replace-scm-with-registry"))
    var replaceSCMWithRegistry = false

    @Flag(name: .customLong("use-registry-identity-for-scm"))
    var useRegistryIdentityForSCM = false

    @Option(name: .customLong("default-registry-url"))
    var defaultRegistryURL: String?

    @Flag(name: .customLong("disable-scm-to-registry-transformation"))
    var disableSCMToRegistryTransformation = false

    @Flag(name: [.customShort("q"), .customLong("quiet")])
    var quiet = false

    @Flag(name: .customLong("disable-package-info-cache"))
    var disablePackageInfoCache = false

    @Option(name: .customLong("package-info-cache-path"))
    var packageInfoCachePath: String?

    @Argument
    var action: CLIAction

    @Argument(parsing: .allUnrecognized)
    var commandArguments: [String] = []

    mutating func run() async throws {
        try await runAsync()
    }

    mutating func runAsync() async throws {
        try await runCLI(try makeCLI())
    }

    func makeCLI() throws -> CLI {
        let command: CLI.Command
        switch action {
        case .resolve:
            command = .resolve(try ResolveArguments.parse(commandArguments).makeOptions())
        case .update:
            command = .update(try UpdateArguments.parse(commandArguments).makeOptions())
        case .restore:
            command = .restore(try RestoreArguments.parse(commandArguments).makeOptions())
        }

        return CLI(
            chdir: fileURL(chdir),
            packagePath: fileURL(packagePath),
            cachePath: fileURL(cachePath),
            scratchPath: fileURL(scratchPath),
            buildPath: fileURL(buildPath),
            configPath: fileURL(configPath),
            securityPath: fileURL(securityPath),
            disableSandbox: disableSandbox,
            enableDependencyCache: enableDependencyCache,
            disableDependencyCache: disableDependencyCache,
            skipUpdate: skipUpdate,
            forceResolvedVersions: forceResolvedVersions,
            disableAutomaticResolution: disableAutomaticResolution,
            onlyUseVersionsFromResolvedFile: onlyUseVersionsFromResolvedFile,
            replaceSCMWithRegistry: replaceSCMWithRegistry,
            useRegistryIdentityForSCM: useRegistryIdentityForSCM,
            defaultRegistryURL: defaultRegistryURL,
            disableSCMToRegistryTransformation: disableSCMToRegistryTransformation,
            quiet: quiet,
            disablePackageInfoCache: disablePackageInfoCache,
            packageInfoCachePath: fileURL(packageInfoCachePath),
            command: command
        )
    }
}

func parseCLI(_ args: [String]) throws -> CLI {
    try SwifterPMCommand.parse(args).makeCLI()
}

private struct ResolveArguments: ParsableArguments {
    @Argument
    var packageName: String?

    @Option(name: .customLong("version"))
    var version: String?

    @Option(name: .customLong("branch"))
    var branch: String?

    @Option(name: .customLong("revision"))
    var revision: String?

    @Option(name: .customLong("package-dir"))
    var packageDir = "."

    @Option(name: .customLong("cache-dir"))
    var cacheDir: String?

    @Flag(name: .customLong("write"))
    var write = false

    @Flag(name: .customLong("restore"))
    var restore = false

    @Flag(name: .customLong("print-only"))
    var printOnly = false

    func makeOptions() -> CLI.ResolveOptions {
        CLI.ResolveOptions(
            packageName: packageName,
            version: version,
            branch: branch,
            revision: revision,
            packageDir: fileURL(packageDir),
            cacheDir: fileURL(cacheDir),
            write: write,
            restore: restore,
            printOnly: printOnly
        )
    }
}

private struct UpdateArguments: ParsableArguments {
    @Argument
    var packageNames: [String] = []

    @Option(name: .customLong("package-dir"))
    var packageDir = "."

    @Option(name: .customLong("cache-dir"))
    var cacheDir: String?

    @Flag(name: .customLong("write"))
    var write = false

    @Flag(name: .customLong("restore"))
    var restore = false

    @Flag(name: .customLong("print-only"))
    var printOnly = false

    func makeOptions() -> CLI.UpdateOptions {
        CLI.UpdateOptions(
            packageNames: packageNames,
            packageDir: fileURL(packageDir),
            cacheDir: fileURL(cacheDir),
            write: write,
            restore: restore,
            printOnly: printOnly
        )
    }
}

private struct RestoreArguments: ParsableArguments {
    @Option(name: .customLong("package-dir"))
    var packageDir = "."

    @Option(name: .customLong("cache-dir"))
    var cacheDir: String?

    @Option(name: .customLong("scratch-dir"))
    var scratchDir: String?

    func makeOptions() -> CLI.RestoreOptions {
        CLI.RestoreOptions(
            packageDir: fileURL(packageDir),
            cacheDir: fileURL(cacheDir),
            scratchDir: fileURL(scratchDir)
        )
    }
}

private func fileURL(_ path: String?) -> URL? {
    path.map(fileURL)
}

private func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: path)
}

func runCLI(_ cli: CLI) async throws {
    if let chdir = cli.chdir {
        guard FileManager.default.changeCurrentDirectoryPath(chdir.path) else {
            throw ToolError.message("failed to change directory to \(chdir.path)")
        }
    }

    switch cli.command {
    case let .resolve(options):
        try ensureWholePackageResolution(
            packageName: options.packageName,
            version: options.version,
            branch: options.branch,
            revision: options.revision
        )
        try await runResolutionCommand(
            cli: cli,
            packageDir: options.packageDir,
            cacheDir: options.cacheDir,
            write: options.write,
            restore: options.restore,
            printOnly: options.printOnly
        )
    case let .update(options):
        if !options.packageNames.isEmpty {
            throw ToolError.message("package-specific update is not supported yet")
        }
        try await runResolutionCommand(
            cli: cli,
            packageDir: options.packageDir,
            cacheDir: options.cacheDir,
            write: options.write,
            restore: options.restore,
            printOnly: options.printOnly
        )
    case let .restore(options):
        let cache = try await Cache(root: cliCacheDir(cli: cli, commandCacheDir: options.cacheDir))
        let package = try await canonicalPackageDir(commandPackageDir(cli: cli, commandPackageDir: options.packageDir))
        let scratch = commandScratchDir(cli: cli, packageDir: package, commandScratchDir: options.scratchDir)
        let registryConfig = try await cliRegistryConfig(cli: cli, package: package)
        let resolved = try await readResolvedFile(packageDir: package)
        try await restorePackage(scratchDir: scratch, cache: cache, registryConfig: registryConfig, resolved: resolved, quiet: cli.quiet)
        try await maybeWritePackageInfoCache(cli: cli, package: package, scratch: scratch, resolved: resolved)
        try await writeWorkspaceState(packageDir: package, scratchDir: scratch, resolved: resolved, disableSandbox: cli.disableSandbox)
    }
}

private func runResolutionCommand(
    cli: CLI,
    packageDir: URL,
    cacheDir: URL?,
    write: Bool,
    restore: Bool,
    printOnly: Bool
) async throws {
    let cache = try await Cache(root: cliCacheDir(cli: cli, commandCacheDir: cacheDir))
    let package = try await canonicalPackageDir(commandPackageDir(cli: cli, commandPackageDir: packageDir))
    let scratch = commandScratchDir(cli: cli, packageDir: package, commandScratchDir: nil)
    let registryConfig = try await cliRegistryConfig(cli: cli, package: package)
    let readOnly = cli.forceResolvedVersions || cli.disableAutomaticResolution || cli.onlyUseVersionsFromResolvedFile

    let resolved: ResolvedPins
    let hasResolvedFile = cli.skipUpdate
        ? try await AsyncFileSystem.exists(package.appendingPathComponent("Package.resolved"))
        : false
    if readOnly || hasResolvedFile {
        resolved = try await readResolvedFile(packageDir: package)
    } else {
        let fresh = try await resolvePackage(packageDir: package, cache: cache, registryConfig: registryConfig, disableSandbox: cli.disableSandbox)
        if shouldWrite(write: write, printOnly: printOnly) {
            try await writeResolvedFile(packageDir: package, resolved: fresh)
        }
        resolved = fresh
    }

    if !cli.quiet {
        printResolution(resolved)
    }
    if shouldRestore(restore: restore, printOnly: printOnly) {
        try await restorePackage(scratchDir: scratch, cache: cache, registryConfig: registryConfig, resolved: resolved, quiet: cli.quiet)
        try await maybeWritePackageInfoCache(cli: cli, package: package, scratch: scratch, resolved: resolved)
        try await writeWorkspaceState(packageDir: package, scratchDir: scratch, resolved: resolved, disableSandbox: cli.disableSandbox)
    }
}

private func maybeWritePackageInfoCache(cli: CLI, package: URL, scratch: URL, resolved: ResolvedPins) async throws {
    if cli.disablePackageInfoCache {
        return
    }
    try await writePackageInfoCache(
        packageDir: package,
        scratchDir: scratch,
        resolved: resolved,
        cacheDir: cli.packageInfoCachePath,
        disableSandbox: cli.disableSandbox,
        quiet: cli.quiet
    )
}

private func ensureWholePackageResolution(packageName: String?, version: String?, branch: String?, revision: String?) throws {
    if packageName != nil || version != nil || branch != nil || revision != nil {
        throw ToolError.message("package-specific resolve is not supported yet")
    }
}

private func shouldWrite(write: Bool, printOnly: Bool) -> Bool {
    !printOnly || write
}

private func shouldRestore(restore: Bool, printOnly: Bool) -> Bool {
    !printOnly || restore
}

private func cliCacheDir(cli: CLI, commandCacheDir: URL?) -> URL? {
    commandCacheDir ?? cli.cachePath
}

private func cliRegistryConfig(cli: CLI, package: URL) async throws -> RegistryConfig {
    try await RegistryConfig.load(packageDir: package, configPath: cli.configPath, defaultRegistryURL: cli.defaultRegistryURL)
}

private func commandPackageDir(cli: CLI, commandPackageDir: URL) -> URL {
    cli.packagePath ?? commandPackageDir
}

private func commandScratchDir(cli: CLI, packageDir: URL, commandScratchDir: URL?) -> URL {
    commandScratchDir ?? cli.scratchPath ?? cli.buildPath ?? packageDir.appendingPathComponent(".build")
}

private func canonicalPackageDir(_ packageDir: URL) async throws -> URL {
    if packageDir.path.hasPrefix("/") {
        return packageDir.standardizedFileURL.resolvingSymlinksInPath()
    }
    return URL(fileURLWithPath: try await AsyncFileSystem.currentDirectoryPath())
        .appendingPathComponent(packageDir.path)
        .standardizedFileURL
        .resolvingSymlinksInPath()
}
