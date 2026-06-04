import Foundation

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

func parseCLI(_ args: [String]) throws -> CLI {
    var index = 0
    var cli = CLI(command: .resolve(.init()))

    func requireValue(_ flag: String) throws -> String {
        guard index + 1 < args.count else {
            throw fail("\(flag) requires a value")
        }
        index += 1
        return args[index]
    }

    while index < args.count {
        let arg = args[index]
        if !arg.hasPrefix("-") {
            break
        }
        switch arg {
        case "--chdir":
            cli.chdir = URL(fileURLWithPath: try requireValue(arg))
        case "--package-path":
            cli.packagePath = URL(fileURLWithPath: try requireValue(arg))
        case "--cache-path":
            cli.cachePath = URL(fileURLWithPath: try requireValue(arg))
        case "--scratch-path":
            cli.scratchPath = URL(fileURLWithPath: try requireValue(arg))
        case "--build-path":
            cli.buildPath = URL(fileURLWithPath: try requireValue(arg))
        case "--config-path":
            cli.configPath = URL(fileURLWithPath: try requireValue(arg))
        case "--security-path":
            cli.securityPath = URL(fileURLWithPath: try requireValue(arg))
        case "--disable-sandbox":
            cli.disableSandbox = true
        case "--enable-dependency-cache":
            cli.enableDependencyCache = true
        case "--disable-dependency-cache":
            cli.disableDependencyCache = true
        case "--skip-update":
            cli.skipUpdate = true
        case "--force-resolved-versions":
            cli.forceResolvedVersions = true
        case "--disable-automatic-resolution":
            cli.disableAutomaticResolution = true
        case "--only-use-versions-from-resolved-file":
            cli.onlyUseVersionsFromResolvedFile = true
        case "--replace-scm-with-registry":
            cli.replaceSCMWithRegistry = true
        case "--use-registry-identity-for-scm":
            cli.useRegistryIdentityForSCM = true
        case "--default-registry-url":
            cli.defaultRegistryURL = try requireValue(arg)
        case "--disable-scm-to-registry-transformation":
            cli.disableSCMToRegistryTransformation = true
        case "--quiet", "-q":
            cli.quiet = true
        case "--disable-package-info-cache":
            cli.disablePackageInfoCache = true
        case "--package-info-cache-path":
            cli.packageInfoCachePath = URL(fileURLWithPath: try requireValue(arg))
        default:
            throw fail("unknown argument: \(arg)")
        }
        index += 1
    }

    guard index < args.count else {
        throw fail("missing command")
    }

    let command = args[index]
    index += 1
    switch command {
    case "resolve":
        cli.command = .resolve(try parseResolveOptions(Array(args[index...])))
    case "update":
        cli.command = .update(try parseUpdateOptions(Array(args[index...])))
    case "restore":
        cli.command = .restore(try parseRestoreOptions(Array(args[index...])))
    default:
        throw fail("unknown command: \(command)")
    }

    return cli
}

private func parseResolveOptions(_ args: [String]) throws -> CLI.ResolveOptions {
    var options = CLI.ResolveOptions()
    var index = 0
    func requireValue(_ flag: String) throws -> String {
        guard index + 1 < args.count else { throw fail("\(flag) requires a value") }
        index += 1
        return args[index]
    }
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--version":
            options.version = try requireValue(arg)
        case "--branch":
            options.branch = try requireValue(arg)
        case "--revision":
            options.revision = try requireValue(arg)
        case "--package-dir":
            options.packageDir = URL(fileURLWithPath: try requireValue(arg))
        case "--cache-dir":
            options.cacheDir = URL(fileURLWithPath: try requireValue(arg))
        case "--write":
            options.write = true
        case "--restore":
            options.restore = true
        case "--print-only":
            options.printOnly = true
        default:
            if arg.hasPrefix("-") {
                throw fail("unknown argument: \(arg)")
            }
            if options.packageName == nil {
                options.packageName = arg
            } else {
                throw fail("unexpected argument: \(arg)")
            }
        }
        index += 1
    }
    return options
}

private func parseUpdateOptions(_ args: [String]) throws -> CLI.UpdateOptions {
    var options = CLI.UpdateOptions()
    var index = 0
    func requireValue(_ flag: String) throws -> String {
        guard index + 1 < args.count else { throw fail("\(flag) requires a value") }
        index += 1
        return args[index]
    }
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--package-dir":
            options.packageDir = URL(fileURLWithPath: try requireValue(arg))
        case "--cache-dir":
            options.cacheDir = URL(fileURLWithPath: try requireValue(arg))
        case "--write":
            options.write = true
        case "--restore":
            options.restore = true
        case "--print-only":
            options.printOnly = true
        default:
            if arg.hasPrefix("-") {
                throw fail("unknown argument: \(arg)")
            }
            options.packageNames.append(arg)
        }
        index += 1
    }
    return options
}

private func parseRestoreOptions(_ args: [String]) throws -> CLI.RestoreOptions {
    var options = CLI.RestoreOptions()
    var index = 0
    func requireValue(_ flag: String) throws -> String {
        guard index + 1 < args.count else { throw fail("\(flag) requires a value") }
        index += 1
        return args[index]
    }
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--package-dir":
            options.packageDir = URL(fileURLWithPath: try requireValue(arg))
        case "--cache-dir":
            options.cacheDir = URL(fileURLWithPath: try requireValue(arg))
        case "--scratch-dir":
            options.scratchDir = URL(fileURLWithPath: try requireValue(arg))
        default:
            throw fail("unknown argument: \(arg)")
        }
        index += 1
    }
    return options
}

func runCLI(_ cli: CLI) async throws {
    if let chdir = cli.chdir {
        FileManager.default.changeCurrentDirectoryPath(chdir.path)
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
            throw fail("package-specific update is not supported yet")
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
        let cache = try Cache(root: cliCacheDir(cli: cli, commandCacheDir: options.cacheDir))
        let package = try canonicalPackageDir(commandPackageDir(cli: cli, commandPackageDir: options.packageDir))
        let scratch = commandScratchDir(cli: cli, packageDir: package, commandScratchDir: options.scratchDir)
        let registryConfig = try cliRegistryConfig(cli: cli, package: package)
        let resolved = try readResolvedFile(packageDir: package)
        try await restorePackage(scratchDir: scratch, cache: cache, registryConfig: registryConfig, resolved: resolved, quiet: cli.quiet)
        try await maybeWritePackageInfoCache(cli: cli, package: package, scratch: scratch, resolved: resolved)
        try writeWorkspaceState(packageDir: package, scratchDir: scratch, resolved: resolved, disableSandbox: cli.disableSandbox)
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
    let cache = try Cache(root: cliCacheDir(cli: cli, commandCacheDir: cacheDir))
    let package = try canonicalPackageDir(commandPackageDir(cli: cli, commandPackageDir: packageDir))
    let scratch = commandScratchDir(cli: cli, packageDir: package, commandScratchDir: nil)
    let registryConfig = try cliRegistryConfig(cli: cli, package: package)
    let readOnly = cli.forceResolvedVersions || cli.disableAutomaticResolution || cli.onlyUseVersionsFromResolvedFile

    let resolved: ResolvedPins
    if readOnly || (cli.skipUpdate && FileManager.default.fileExists(atPath: package.appendingPathComponent("Package.resolved").path)) {
        resolved = try readResolvedFile(packageDir: package)
    } else {
        let fresh = try await resolvePackage(packageDir: package, cache: cache, registryConfig: registryConfig, disableSandbox: cli.disableSandbox)
        if shouldWrite(write: write, printOnly: printOnly) {
            try writeResolvedFile(packageDir: package, resolved: fresh)
        }
        resolved = fresh
    }

    if !cli.quiet {
        printResolution(resolved)
    }
    if shouldRestore(restore: restore, printOnly: printOnly) {
        try await restorePackage(scratchDir: scratch, cache: cache, registryConfig: registryConfig, resolved: resolved, quiet: cli.quiet)
        try await maybeWritePackageInfoCache(cli: cli, package: package, scratch: scratch, resolved: resolved)
        try writeWorkspaceState(packageDir: package, scratchDir: scratch, resolved: resolved, disableSandbox: cli.disableSandbox)
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
        throw fail("package-specific resolve is not supported yet")
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

private func cliRegistryConfig(cli: CLI, package: URL) throws -> RegistryConfig {
    try RegistryConfig.load(packageDir: package, configPath: cli.configPath, defaultRegistryURL: cli.defaultRegistryURL)
}

private func commandPackageDir(cli: CLI, commandPackageDir: URL) -> URL {
    cli.packagePath ?? commandPackageDir
}

private func commandScratchDir(cli: CLI, packageDir: URL, commandScratchDir: URL?) -> URL {
    commandScratchDir ?? cli.scratchPath ?? cli.buildPath ?? packageDir.appendingPathComponent(".build")
}

private func canonicalPackageDir(_ packageDir: URL) throws -> URL {
    if packageDir.path.hasPrefix("/") {
        return packageDir.standardizedFileURL.resolvingSymlinksInPath()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(packageDir.path)
        .standardizedFileURL
        .resolvingSymlinksInPath()
}
