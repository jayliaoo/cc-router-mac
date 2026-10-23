import Foundation

/// 模型归属路由（术语见 CONTEXT.md）的核心匹配逻辑（design「3 接口设计」）：
/// 按请求 `model` 与各 Provider 的 `models` **精确匹配**，只命中启用的 Provider。
/// 无通配、无兜底、无顺序仲裁——同一模型至多被一个 Provider 声明，
/// 这在保存配置时由 `ConfigSnapshot.validationErrors` 全局校验保证（与启用状态无关）。
public struct ModelRouter: Sendable {
    /// 参与匹配的 Provider 列表（来自某一时刻的 ConfigSnapshot）。
    public let providers: [Provider]

    public init(providers: [Provider]) {
        self.providers = providers
    }

    /// 返回精确声明该 model 且启用的 Provider；未命中返回 nil
    /// （含「仅被禁用 Provider 声明」与「无任何 Provider 声明」两种情况）。
    public func provider(forModel model: String) -> Provider? {
        self.providers.first { $0.enabled && $0.models.contains(model) }
    }
}
