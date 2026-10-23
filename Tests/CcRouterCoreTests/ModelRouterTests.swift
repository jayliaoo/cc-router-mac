import Testing

@testable import CcRouterCore

/// 模型归属路由（CONTEXT.md）的纯逻辑单元测试：
/// 匹配规则本身（命中 / 未命中 / 精确性 / 跨启用状态）。
/// 端到端行为在 `ModelRoutingEndToEndTests` 的 HTTP seam 上断言。
@Suite("模型归属路由（纯逻辑）")
struct ModelRouterTests {
    private func makeProvider(_ name: String, models: [String], enabled: Bool) -> Provider {
        Provider(
            name: name,
            baseUrl: "https://example.invalid",
            apiKey: "key-\(name)",
            models: models,
            enabled: enabled
        )
    }

    @Test("命中：model 被启用的 Provider 声明 → 返回该 Provider")
    func hitsEnabledClaimant() {
        let a = makeProvider("A", models: ["model-a"], enabled: true)
        let b = makeProvider("B", models: ["model-b"], enabled: true)
        let router = ModelRouter(providers: [a, b])

        #expect(router.provider(forModel: "model-a") == a)
        #expect(router.provider(forModel: "model-b") == b)
    }

    @Test("未命中：没有任何 Provider 声明该 model")
    func missesUnknownModel() {
        let router = ModelRouter(providers: [makeProvider("A", models: ["model-a"], enabled: true)])

        #expect(router.provider(forModel: "model-x") == nil)
        #expect(router.provider(forModel: "") == nil)
    }

    @Test("精确匹配：不做前缀或子串匹配")
    func matchesExactly() {
        let router = ModelRouter(providers: [makeProvider("A", models: ["claude-sonnet"], enabled: true)])

        #expect(router.provider(forModel: "claude-sonnet-5") == nil)
        #expect(router.provider(forModel: "claude") == nil)
    }

    @Test("跨启用状态：model 只被禁用的 Provider 声明 → 未命中")
    func skipsDisabledClaimant() {
        let disabled = makeProvider("A", models: ["model-a"], enabled: false)
        let enabled = makeProvider("B", models: ["model-b"], enabled: true)
        let router = ModelRouter(providers: [disabled, enabled])

        #expect(router.provider(forModel: "model-a") == nil)
        #expect(router.provider(forModel: "model-b") == enabled)
    }
}
