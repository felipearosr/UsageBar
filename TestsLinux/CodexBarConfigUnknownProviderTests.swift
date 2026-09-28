import CodexBarCore
import Foundation
import Testing

struct CodexBarConfigUnknownProviderTests {
    private static let configWithFutureProvider = """
    {
      "version": 1,
      "providers": [
        { "id": "codex", "enabled": true },
        { "id": "futureprovider", "enabled": false, "region": "intl", "limits": [5, 1.5], "extra": null },
        { "id": "claude", "enabled": true, "source": "oauth" }
      ]
    }
    """

    @Test
    func `unknown provider ids decode instead of failing the whole config`() throws {
        let config = try JSONDecoder().decode(
            CodexBarConfig.self,
            from: Data(Self.configWithFutureProvider.utf8))

        #expect(config.providers.map(\.id) == [.codex, .claude])
        #expect(config.enabledProviders() == [.codex, .claude])
        #expect(config.providerConfig(for: .claude)?.source == .oauth)
        #expect(config.unknownProviders.count == 1)
    }

    @Test
    func `store load and save keep unknown provider entries`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-unknown-provider-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try Data(Self.configWithFutureProvider.utf8).write(to: store.fileURL)

        var config = try #require(try store.load())
        config.setProviderConfig(ProviderConfig(id: .codex, enabled: false))
        try store.save(config)

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        let providers = try #require(saved?["providers"] as? [[String: Any]])
        let future = try #require(providers.first { $0["id"] as? String == "futureprovider" })
        #expect(future["enabled"] as? Bool == false)
        #expect(future["region"] as? String == "intl")
        #expect(future["limits"] as? [Double] == [5, 1.5])
        #expect(future.keys.contains("extra"))
        #expect(providers.first { $0["id"] as? String == "codex" }?["enabled"] as? Bool == false)

        let reloaded = try #require(try store.load())
        #expect(reloaded.unknownProviders == config.unknownProviders)
    }

    @Test
    func `malformed known provider entries still fail to decode`() {
        let json = #"{ "version": 1, "providers": [ { "id": "codex", "enabled": "yes" } ] }"#

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CodexBarConfig.self, from: Data(json.utf8))
        }
    }
}
