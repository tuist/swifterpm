import Foundation

enum Environment {
    @TaskLocal
    static var values: [String: String]?

    static var isCI: Bool {
        ["GITHUB_RUN_ID", "CI", "BUILD_NUMBER"].contains { environment[$0] != nil }
    }

    private static var environment: [String: String] {
        values ?? ProcessInfo.processInfo.environment
    }
}
