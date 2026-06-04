import Foundation
import Testing

struct RegistryTests {
    @Test
    func loadUsesProvidedDefaultRegistryURL() async throws {
        try await withTemporaryDirectory { root in
            let config = try await RegistryConfig.load(
                packageDir: root,
                configPath: nil,
                defaultRegistryURL: "https://registry.example.com"
            )

            #expect(
                try config.registryURL(for: uniqueRegistryIdentity()).absoluteString
                    == "https://registry.example.com")
        }
    }

    @Test
    func loadReadsPackageScopedRegistryConfig() async throws {
        try await withTemporaryDirectory { root in
            let scope = uniqueRegistryScope()
            let registries = root.appendingPathComponent(".swiftpm/configuration/registries.json")
            try await AsyncFileSystem.atomicWrite(
                """
                {
                  "registries": {
                    "\(scope)": {
                      "url": "https://\(scope).example.com"
                    }
                  }
                }
                """,
                to: registries
            )

            let config = try await RegistryConfig.load(
                packageDir: root, configPath: nil, defaultRegistryURL: nil)

            #expect(
                try config.registryURL(for: "\(scope).package").absoluteString
                    == "https://\(scope).example.com")
        }
    }

    @Test
    func registryVersionSemverRejectsInvalidVersions() {
        #expect(RegistryVersion(version: "1.2.3").semver?.description == "1.2.3")
        #expect(RegistryVersion(version: "branch").semver == nil)
    }

    private func uniqueRegistryIdentity() -> String {
        "\(uniqueRegistryScope()).package"
    }

    private func uniqueRegistryScope() -> String {
        "scope\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased())"
    }
}
