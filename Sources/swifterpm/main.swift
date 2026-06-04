import Foundation

let swifterpmVersion = "0.1.0"
let swifterpmHelp = """
swifterpm \(swifterpmVersion)

USAGE:
  swifterpm [OPTIONS] <resolve|update|restore> [COMMAND OPTIONS]

OPTIONS:
  --package-path <path>
  --cache-path <path>
  --scratch-path <path>
  --build-path <path>
  --config-path <path>
  --default-registry-url <url>
  --skip-update
  --force-resolved-versions
  --disable-automatic-resolution
  --only-use-versions-from-resolved-file
  --disable-package-info-cache
  --quiet
  --version
  --help
"""

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") || args.contains("-h") {
        print(swifterpmHelp)
        Foundation.exit(0)
    }
    if args.contains("--version") || args.contains("-V") {
        print(swifterpmVersion)
        Foundation.exit(0)
    }
    let cli = try parseCLI(args)
    try await runCLI(cli)
} catch {
    fputs("\(error)\n", stderr)
    Foundation.exit(1)
}
