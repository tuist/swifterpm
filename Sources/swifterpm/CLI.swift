import ArgumentParser
import Foundation

let swifterpmVersion = "0.1.0"

struct CLIPath: Equatable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    static func optional(_ path: String?) -> CLIPath? {
        path.map(CLIPath.init)
    }

    var path: String {
        URL(fileURLWithPath: rawValue).path
    }

    func resolved(relativeTo baseDirectory: URL) -> URL {
        if rawValue.hasPrefix("/") {
            return URL(fileURLWithPath: rawValue).standardizedFileURL
        }
        return baseDirectory
            .appendingPathComponent(rawValue)
            .standardizedFileURL
    }
}

struct CLI {
    var chdir: CLIPath?
    var packagePath: CLIPath?
    var cachePath: CLIPath?
    var scratchPath: CLIPath?
    var buildPath: CLIPath?
    var configPath: CLIPath?
    var securityPath: CLIPath?
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
    var packageInfoCachePath: CLIPath?
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
        var packageDir = CLIPath(".")
        var cacheDir: CLIPath?
        var write = false
        var restore = false
        var printOnly = false
    }

    struct UpdateOptions {
        var packageNames: [String] = []
        var packageDir = CLIPath(".")
        var cacheDir: CLIPath?
        var write = false
        var restore = false
        var printOnly = false
    }

    struct RestoreOptions {
        var packageDir = CLIPath(".")
        var cacheDir: CLIPath?
        var scratchDir: CLIPath?
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
        try await CLIRunner.run(try makeCLI())
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
            chdir: CLIPath.optional(chdir),
            packagePath: CLIPath.optional(packagePath),
            cachePath: CLIPath.optional(cachePath),
            scratchPath: CLIPath.optional(scratchPath),
            buildPath: CLIPath.optional(buildPath),
            configPath: CLIPath.optional(configPath),
            securityPath: CLIPath.optional(securityPath),
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
            packageInfoCachePath: CLIPath.optional(packageInfoCachePath),
            command: command
        )
    }
}

enum CLIParser {
    static func parse(_ args: [String]) throws -> CLI {
        try SwifterPMCommand.parse(args).makeCLI()
    }
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
            packageDir: CLIPath(packageDir),
            cacheDir: CLIPath.optional(cacheDir),
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
            packageDir: CLIPath(packageDir),
            cacheDir: CLIPath.optional(cacheDir),
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
            packageDir: CLIPath(packageDir),
            cacheDir: CLIPath.optional(cacheDir),
            scratchDir: CLIPath.optional(scratchDir)
        )
    }
}

struct CLIPathResolver {
    let baseDirectory: URL

    init(chdir: CLIPath?) async throws {
        let currentDirectory = URL(
            fileURLWithPath: try await AsyncFileSystem.currentDirectoryPath(),
            isDirectory: true
        )
        guard let chdir else {
            baseDirectory = currentDirectory.standardizedFileURL
            return
        }

        let resolvedChdir = chdir.resolved(relativeTo: currentDirectory)
        guard try await AsyncFileSystem.isDirectory(resolvedChdir) else {
            throw ToolError.message("failed to change directory to \(resolvedChdir.path)")
        }
        baseDirectory = resolvedChdir.standardizedFileURL
    }

    func resolve(_ path: CLIPath?) -> URL? {
        path.map(resolve)
    }

    func resolve(_ path: CLIPath) -> URL {
        path.resolved(relativeTo: baseDirectory)
    }
}

enum CLIRunner {
    static func run(_ cli: CLI) async throws {
        let paths = try await CLIPathResolver(chdir: cli.chdir)

        switch cli.command {
        case .resolve(let options):
            try ensureWholePackageResolution(
                packageName: options.packageName,
                version: options.version,
                branch: options.branch,
                revision: options.revision
            )
            try await runResolutionCommand(
                cli: cli,
                paths: paths,
                packageDir: options.packageDir,
                cacheDir: options.cacheDir,
                preferResolvedFile: true,
                write: options.write,
                restore: options.restore,
                printOnly: options.printOnly
            )
        case .update(let options):
            if !options.packageNames.isEmpty {
                throw ToolError.message("package-specific update is not supported yet")
            }
            try await runResolutionCommand(
                cli: cli,
                paths: paths,
                packageDir: options.packageDir,
                cacheDir: options.cacheDir,
                preferResolvedFile: false,
                write: options.write,
                restore: options.restore,
                printOnly: options.printOnly
            )
        case .restore(let options):
            let cache = try await Cache(
                root: cliCacheDir(cli: cli, paths: paths, commandCacheDir: options.cacheDir))
            let package = canonicalPackageDir(
                commandPackageDir(
                    cli: cli, paths: paths, commandPackageDir: options.packageDir))
            let scratch = commandScratchDir(
                cli: cli, paths: paths, packageDir: package, commandScratchDir: options.scratchDir)
            let registryConfig = try await cliRegistryConfig(
                cli: cli, paths: paths, package: package)
            let resolved = try await ResolvedFile.read(packageDir: package)
            try await WorkspaceRestorer.restorePackage(
                scratchDir: scratch, packageDir: package, cache: cache, registryConfig: registryConfig,
                resolved: resolved,
                quiet: cli.quiet,
                disableSandbox: cli.disableSandbox)
            try await maybeWritePackageInfoCache(
                cli: cli, paths: paths, package: package, scratch: scratch, resolved: resolved)
            try await WorkspaceRestorer.writeWorkspaceState(
                packageDir: package, scratchDir: scratch, resolved: resolved,
                disableSandbox: cli.disableSandbox)
        }
    }

    private static func runResolutionCommand(
        cli: CLI,
        paths: CLIPathResolver,
        packageDir: CLIPath,
        cacheDir: CLIPath?,
        preferResolvedFile: Bool,
        write: Bool,
        restore: Bool,
        printOnly: Bool
    ) async throws {
        let cache = try await Cache(
            root: cliCacheDir(cli: cli, paths: paths, commandCacheDir: cacheDir))
        let package = canonicalPackageDir(
            commandPackageDir(cli: cli, paths: paths, commandPackageDir: packageDir))
        let scratch = commandScratchDir(
            cli: cli, paths: paths, packageDir: package, commandScratchDir: nil)
        let registryConfig = try await cliRegistryConfig(
            cli: cli, paths: paths, package: package)
        let readOnly =
            cli.forceResolvedVersions || cli.disableAutomaticResolution
            || cli.onlyUseVersionsFromResolvedFile

        let resolved: ResolvedPins
        let hasResolvedFile =
            cli.skipUpdate
            ? try await AsyncFileSystem.exists(package.appendingPathComponent("Package.resolved"))
            : false
        if readOnly || hasResolvedFile {
            resolved = try await ResolvedFile.read(packageDir: package)
        } else if preferResolvedFile,
                  let existing = try await ResolvedFile.readIfCurrent(packageDir: package)
        {
            resolved = existing
        } else {
            let progress = cli.quiet ? nil : ResolutionProgressReporter()
            let fresh = try await PackageResolver.resolve(
                packageDir: package, cache: cache, registryConfig: registryConfig,
                disableSandbox: cli.disableSandbox,
                progress: progress)
            if shouldWrite(write: write, printOnly: printOnly) {
                try await ResolvedFile.write(packageDir: package, resolved: fresh)
            }
            resolved = fresh
        }

        if !cli.quiet {
            ResolvedFile.print(resolved)
        }
        if shouldRestore(restore: restore, printOnly: printOnly) {
            try await WorkspaceRestorer.restorePackage(
                scratchDir: scratch, packageDir: package, cache: cache, registryConfig: registryConfig,
                resolved: resolved,
                quiet: cli.quiet,
                disableSandbox: cli.disableSandbox)
            try await maybeWritePackageInfoCache(
                cli: cli, paths: paths, package: package, scratch: scratch, resolved: resolved)
            try await WorkspaceRestorer.writeWorkspaceState(
                packageDir: package, scratchDir: scratch, resolved: resolved,
                disableSandbox: cli.disableSandbox)
        }
    }

    private static func maybeWritePackageInfoCache(
        cli: CLI, paths: CLIPathResolver, package: URL, scratch: URL, resolved: ResolvedPins
    ) async throws {
        if cli.disablePackageInfoCache {
            return
        }
        try await PackageInfoCacheWriter.write(
            packageDir: package,
            scratchDir: scratch,
            resolved: resolved,
            cacheDir: paths.resolve(cli.packageInfoCachePath),
            disableSandbox: cli.disableSandbox,
            quiet: cli.quiet
        )
    }

    private static func ensureWholePackageResolution(
        packageName: String?, version: String?, branch: String?, revision: String?
    ) throws {
        if packageName != nil || version != nil || branch != nil || revision != nil {
            throw ToolError.message("package-specific resolve is not supported yet")
        }
    }

    private static func shouldWrite(write: Bool, printOnly: Bool) -> Bool {
        !printOnly || write
    }

    private static func shouldRestore(restore: Bool, printOnly: Bool) -> Bool {
        !printOnly || restore
    }

    private static func cliCacheDir(cli: CLI, paths: CLIPathResolver, commandCacheDir: CLIPath?)
        -> URL?
    {
        paths.resolve(commandCacheDir ?? cli.cachePath)
    }

    private static func cliRegistryConfig(
        cli: CLI, paths: CLIPathResolver, package: URL
    ) async throws
        -> RegistryConfig
    {
        try await RegistryConfig.load(
            packageDir: package, configPath: paths.resolve(cli.configPath),
            defaultRegistryURL: cli.defaultRegistryURL)
    }

    private static func commandPackageDir(
        cli: CLI, paths: CLIPathResolver, commandPackageDir: CLIPath
    )
        -> URL
    {
        paths.resolve(cli.packagePath ?? commandPackageDir)
    }

    private static func commandScratchDir(
        cli: CLI, paths: CLIPathResolver, packageDir: URL, commandScratchDir: CLIPath?
    ) -> URL
    {
        if let scratchDir = commandScratchDir ?? cli.scratchPath ?? cli.buildPath {
            return paths.resolve(scratchDir)
        }
        return packageDir.appendingPathComponent(".build")
    }

    private static func canonicalPackageDir(_ packageDir: URL) -> URL {
        packageDir.standardizedFileURL
    }
}
