import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Darwin)
    import Darwin
#endif

final class ResolutionProgressReporter: @unchecked Sendable {
    private struct State {
        let startedAt = Date()
        let rootVersionedDependencies: Int
        let fixedDependencies: Int
        var fetchedMetadata = Set<String>()
        var inspectedManifests = Set<String>()
        var selectedPackages = Set<String>()
        var fixedPinPackages = Set<String>()
        var discoveredPackages = 0
        var lastProgressAt = Date.distantPast
        var lastProgressLine: String?
        var renderedInteractiveProgress = false
    }

    private let enabled: Bool
    private let interactive: Bool
    private let minimumInterval: TimeInterval
    private let writeOutput: @Sendable (String) -> Void
    private let lock = NSLock()
    private var state: State?

    init(
        enabled: Bool = true,
        interactive: Bool = TerminalStyle.colorEnabled,
        minimumInterval: TimeInterval = 2,
        writeOutput: @escaping @Sendable (String) -> Void = { output in
            ResolutionProgressReporter.writeStderr(output)
        }
    ) {
        self.enabled = enabled
        self.interactive = interactive
        self.minimumInterval = minimumInterval
        self.writeOutput = writeOutput
    }

    init(
        enabled: Bool = true,
        minimumInterval: TimeInterval,
        writeLine: @escaping @Sendable (String) -> Void
    ) {
        self.enabled = enabled
        self.interactive = false
        self.minimumInterval = minimumInterval
        self.writeOutput = { output in
            for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                writeLine(String(line))
            }
        }
    }

    func started(rootVersionedDependencies: Int, fixedDependencies: Int) {
        guard enabled else { return }
        withLock {
            state = State(
                rootVersionedDependencies: rootVersionedDependencies,
                fixedDependencies: fixedDependencies
            )
            writeLine("\(TerminalStyle.bold("swifterpm")) \(TerminalStyle.dim(swifterpmVersion))")
        }
    }

    func startedFetchingVersions(package: String) {
        emitProgress()
    }

    func finishedFetchingVersions(package: String, versionCount: Int) {
        withLock {
            guard var current = state else { return }
            current.fetchedMetadata.insert(package)
            state = current
        }
        emitProgress()
    }

    func selected(package: String, version: String) {
        withLock {
            guard var current = state else { return }
            current.selectedPackages.insert(package)
            state = current
        }
        emitProgress()
    }

    func startedInspectingManifest(package: String, version: String) {
        emitProgress()
    }

    func finishedInspectingManifest(package: String, version: String, dependencyCount: Int) {
        withLock {
            guard var current = state else { return }
            current.inspectedManifests.insert("\(package)@\(version)")
            current.discoveredPackages += dependencyCount
            state = current
        }
        emitProgress()
    }

    func startedResolvingFixedPin(package: String) {
        emitProgress()
    }

    func finishedResolvingFixedPin(package: String) {
        withLock {
            guard var current = state else { return }
            current.fixedPinPackages.insert(package)
            state = current
        }
        emitProgress()
    }

    func finished(pinCount: Int) {
        guard enabled else { return }
        withLock {
            guard let current = state else { return }
            let elapsed = TerminalStyle.dim(
                Self.formatDuration(Date().timeIntervalSince(current.startedAt)))
            let summary =
                "\(TerminalStyle.green("✓")) resolved \(TerminalStyle.bold("\(pinCount)")) package\(pinCount == 1 ? "" : "s") in \(elapsed)"
            if interactive, current.renderedInteractiveProgress {
                writeOutput("\r\u{001B}[2K\(summary)\n")
            } else {
                writeLine(summary)
            }
            state = nil
        }
    }

    private func emitProgress() {
        guard enabled else { return }
        withLock {
            guard var current = state else { return }
            let now = Date()
            guard now.timeIntervalSince(current.lastProgressAt) >= minimumInterval else {
                state = current
                return
            }
            let line = Self.progressLine(state: current)
            guard current.lastProgressLine != line else {
                state = current
                return
            }
            current.lastProgressAt = now
            current.lastProgressLine = line
            if interactive {
                writeOutput("\r\u{001B}[2K\(line)")
                current.renderedInteractiveProgress = true
            } else {
                writeLine(line)
            }
            state = current
        }
    }

    private static func progressLine(state: State) -> String {
        let resolvedPackages = state.selectedPackages.union(state.fixedPinPackages).count
        let targetPackages = max(
            state.rootVersionedDependencies + state.fixedDependencies + state.discoveredPackages,
            resolvedPackages
        )
        let count: String
        if targetPackages > resolvedPackages {
            count =
                "\(paddedCount(resolvedPackages, total: targetPackages))/\(targetPackages)"
        } else {
            count = paddedCount(resolvedPackages, total: resolvedPackages)
        }
        return
            "\(TerminalStyle.bold(count)) \(TerminalStyle.dim("deps")) \(TerminalStyle.dim("·")) \(TerminalStyle.cyan("resolving"))"
    }

    private static func paddedCount(_ count: Int, total: Int) -> String {
        let width = max(4, String(total).count)
        return String(format: "%\(width)d", count)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func writeStderr(_ output: String) {
        FileHandle.standardError.write(Data(output.utf8))
    }

    private func writeLine(_ line: String) {
        writeOutput(line + "\n")
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded()))ms"
        }
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let totalSeconds = Int(seconds.rounded())
        return "\(totalSeconds / 60)m\(String(format: "%02d", totalSeconds % 60))s"
    }
}

private enum TerminalStyle {
    static func bold(_ value: String) -> String {
        styled(value, code: "1")
    }

    static func cyan(_ value: String) -> String {
        styled(value, code: "36")
    }

    static func dim(_ value: String) -> String {
        styled(value, code: "2")
    }

    static func green(_ value: String) -> String {
        styled(value, code: "32")
    }

    private static func styled(_ value: String, code: String) -> String {
        guard colorEnabled else { return value }
        return "\u{001B}[\(code)m\(value)\u{001B}[0m"
    }

    fileprivate static var colorEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["NO_COLOR"] != nil {
            return false
        }
        if let force = env["CLICOLOR_FORCE"], truthy(force) {
            return true
        }
        if env["CLICOLOR"] == "0" {
            return false
        }
        return isatty(FileHandle.standardError.fileDescriptor) == 1
    }

    private static func truthy(_ value: String) -> Bool {
        !["", "0", "false", "no", "off"].contains(value.lowercased())
    }
}
