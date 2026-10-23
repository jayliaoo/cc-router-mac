/// 一个上游 Anthropic 兼容端点的配置（术语见 CONTEXT.md：Provider）。
public struct Provider: Sendable, Equatable {
    public let name: String
    public let baseUrl: String
    public let apiKey: String
    public let models: [String]
    public let enabled: Bool

    public init(name: String, baseUrl: String, apiKey: String, models: [String], enabled: Bool) {
        self.name = name
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.models = models
        self.enabled = enabled
    }
}
