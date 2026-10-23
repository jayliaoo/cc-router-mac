import Foundation

/// 一个上游 Anthropic 兼容端点的配置（术语见 CONTEXT.md：Provider）。
/// `id` 在配置内全局唯一，UI 据此定位与标红冲突项。
/// Codable 字段与 config.json 中的 Provider 结构一一对应（design「数据设计」）。
public struct Provider: Sendable, Equatable, Codable {
    public let id: UUID
    public let name: String
    public let baseUrl: String
    public let apiKey: String
    public let models: [String]
    public let enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        baseUrl: String,
        apiKey: String,
        models: [String],
        enabled: Bool
    ) {
        self.id = id
        self.name = name
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.models = models
        self.enabled = enabled
    }
}
