import Foundation
import Testing

@testable import CcRouterCore

// Seam（任务 02）：纯逻辑单元——保存校验、JSON round-trip、快照交换、持久化。
// 全部走 ConfigSnapshot / ConfigStore 公共接口；持久化测试只写临时目录。

@Suite("ConfigStore：保存时校验")
struct ConfigValidationTests {
    private func makeProvider(
        id: UUID = UUID(),
        name: String = "官方",
        baseUrl: String = "https://api.anthropic.com",
        apiKey: String = "sk-test",
        models: [String] = ["claude-sonnet-5-5"],
        enabled: Bool = true
    ) -> Provider {
        Provider(id: id, name: name, baseUrl: baseUrl, apiKey: apiKey, models: models, enabled: enabled)
    }

    private func makeSnapshot(providers: [Provider]) -> ConfigSnapshot {
        ConfigSnapshot(
            gatewayEnabled: true,
            listen: ListenConfig(address: "127.0.0.1", port: 8317),
            providers: providers
        )
    }

    @Test("空模型列表：校验拒绝，错误可定位到该 Provider")
    func rejectsEmptyModels() {
        let emptyProvider = makeProvider(name: "空列表商", models: [])
        let errors = makeSnapshot(providers: [emptyProvider]).validationErrors()

        #expect(errors == [.emptyModels(provider: emptyProvider)])
        #expect(errors.first?.description.contains("空列表商") == true)
    }

    @Test("跨 Provider 重复模型：即使重复项中有 Provider 被禁用也拒绝，错误列出全部声明方")
    func rejectsModelClaimedByMultipleProvidersRegardlessOfEnabledState() {
        let first = makeProvider(name: "官方", models: ["claude-sonnet-5-5"])
        let secondDisabled = makeProvider(name: "备用商", models: ["claude-sonnet-5-5", "claude-opus-4"], enabled: false)
        let errors = makeSnapshot(providers: [first, secondDisabled]).validationErrors()

        #expect(errors == [
            .modelClaimedByMultipleProviders(model: "claude-sonnet-5-5", providers: [first, secondDisabled]),
        ])
    }

    @Test("非法 baseUrl：无 scheme、带空格、纯主机名均被拒绝")
    func rejectsInvalidBaseUrl() {
        for badUrl in ["api.anthropic.com", "https://exa mple.com", "https://"] {
            let provider = makeProvider(baseUrl: badUrl)
            let errors = makeSnapshot(providers: [provider]).validationErrors()
            #expect(errors == [.invalidBaseUrl(provider: provider)])
        }
    }

    @Test("空 apiKey：被拒绝，错误可定位到该 Provider")
    func rejectsEmptyApiKey() {
        let provider = makeProvider(name: "无密商", apiKey: "")
        let errors = makeSnapshot(providers: [provider]).validationErrors()

        #expect(errors == [.emptyApiKey(provider: provider)])
        #expect(errors.first?.description.contains("无密商") == true)
    }

    @Test("重复 Provider id：被拒绝，错误列出全部同 id 项")
    func rejectsDuplicateProviderId() {
        let sharedId = UUID()
        let first = makeProvider(id: sharedId, name: "甲")
        let second = makeProvider(id: sharedId, name: "乙", models: ["claude-opus-4"])
        let errors = makeSnapshot(providers: [first, second]).validationErrors()

        #expect(errors == [.duplicateProviderId(id: sharedId, providers: [first, second])])
    }

    @Test("合法配置：校验无问题")
    func acceptsValidConfig() {
        let providers = [
            makeProvider(name: "官方", models: ["claude-sonnet-5-5", "claude-opus-4"]),
            makeProvider(name: "第三方", baseUrl: "http://127.0.0.1:9000", models: ["glm-5"], enabled: false),
        ]
        #expect(makeSnapshot(providers: providers).validationErrors().isEmpty)
    }
}

@Suite("ConfigStore：持久化与快照交换")
struct ConfigStorePersistenceTests {
    /// 每个测试独享一个临时目录，不碰真实 Application Support（任务 02 seam 约定）。
    private func makeFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-router-config-tests-\(UUID().uuidString)", isDirectory: true)
        return directory.appendingPathComponent("config.json")
    }

    private func makeProvider(
        name: String = "官方",
        baseUrl: String = "https://api.anthropic.com",
        apiKey: String = "sk-ant-test",
        models: [String] = ["claude-sonnet-5-5"],
        enabled: Bool = true
    ) -> Provider {
        Provider(id: UUID(), name: name, baseUrl: baseUrl, apiKey: apiKey, models: models, enabled: enabled)
    }

    private func makeSnapshot(providers: [Provider], gatewayEnabled: Bool = true) -> ConfigSnapshot {
        ConfigSnapshot(
            gatewayEnabled: gatewayEnabled,
            listen: ListenConfig(address: "127.0.0.1", port: 8317),
            providers: providers
        )
    }

    @Test("合法配置 JSON ↔ 内存模型 round-trip 无损（含中文等非 ASCII）")
    func roundTripsThroughJSONFile() async throws {
        let fileURL = try makeFileURL()
        let snapshot = makeSnapshot(providers: [
            makeProvider(name: "官方", apiKey: "sk-ant-官方-key", models: ["claude-sonnet-5-5"]),
            makeProvider(name: "第三方·智谱", baseUrl: "https://open.example.cn", models: ["glm-5", "glm-5-air"], enabled: false),
        ])
        let store = ConfigStore(fileURL: fileURL, snapshot: .default)
        try await store.save(snapshot)

        let reloaded = try ConfigStore.load(from: fileURL)
        let reloadedSnapshot = await reloaded.current()
        #expect(reloadedSnapshot == snapshot)
    }

    @Test("save 走临时文件 + rename：落盘文件权限 0600，二次保存覆盖旧内容且无临时文件残留")
    func savesAtomicallyWithOwnerOnlyPermissions() async throws {
        let fileURL = try makeFileURL()
        let store = ConfigStore(fileURL: fileURL, snapshot: .default)
        let first = makeSnapshot(providers: [makeProvider(name: "第一次")])
        try await store.save(first)

        func filePermissions() throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            return attributes[.posixPermissions] as? Int ?? -1
        }
        #expect(try filePermissions() == 0o600)

        let second = makeSnapshot(providers: [makeProvider(name: "第二次", models: ["glm-5"])])
        try await store.save(second)

        #expect(try filePermissions() == 0o600)
        // rename 覆盖了旧内容，而非追加或旁置
        let reloaded = try ConfigStore.load(from: fileURL)
        #expect(await reloaded.current() == second)

        // 临时文件已被 rename 消化，目录里只剩 config.json
        let directoryContents = try FileManager.default.contentsOfDirectory(
            atPath: fileURL.deletingLastPathComponent().path
        )
        #expect(directoryContents == ["config.json"])
    }

    @Test("校验失败的 save：不落盘、不改内存快照")
    func rejectedSaveLeavesDiskAndMemoryUntouched() async throws {
        let fileURL = try makeFileURL()
        let valid = makeSnapshot(providers: [makeProvider(name: "合法配置")])
        let store = ConfigStore(fileURL: fileURL, snapshot: .default)
        try await store.save(valid)

        let conflicting = makeSnapshot(providers: [
            makeProvider(name: "甲", models: ["claude-sonnet-5-5"]),
            makeProvider(name: "乙", models: ["claude-sonnet-5-5"]),
        ])
        do {
            try await store.save(conflicting)
            Issue.record("重复模型的配置应当被保存校验拒绝")
        } catch let error as ConfigStore.SaveError {
            #expect(error.errors.first.map {
                if case .modelClaimedByMultipleProviders = $0 { true } else { false }
            } == true)
        }

        // 磁盘仍是先前的合法配置
        let reloaded = try ConfigStore.load(from: fileURL)
        #expect(await reloaded.current() == valid)
        // 内存快照未被改动
        #expect(await store.current() == valid)
        // 目录里没有校验失败留下的半成品
        let directoryContents = try FileManager.default.contentsOfDirectory(
            atPath: fileURL.deletingLastPathComponent().path
        )
        #expect(directoryContents == ["config.json"])
    }

    @Test("快照交换原子生效：新读请求见新配置，持有旧快照的『请求』不受影响")
    func snapshotExchangeIsAtomic() async throws {
        let fileURL = try makeFileURL()
        let old = makeSnapshot(providers: [makeProvider(name: "旧", models: ["claude-sonnet-5-5"])])
        let new = makeSnapshot(
            providers: [makeProvider(name: "新", baseUrl: "https://new.example.com", models: ["glm-5"])],
            gatewayEnabled: false
        )
        let store = ConfigStore(fileURL: fileURL, snapshot: old)

        // 请求入口先取当下快照（design 5.1），此后全程使用它
        let inFlightSnapshot = await store.current()
        #expect(inFlightSnapshot == old)

        try await store.save(new)

        // 交换后：新读请求见新配置
        #expect(await store.current() == new)
        // 在途『请求』持有的旧快照不受交换影响，仍按旧配置完成
        #expect(inFlightSnapshot == old)
        #expect(inFlightSnapshot.providers.map(\.name) == ["旧"])
    }
}
