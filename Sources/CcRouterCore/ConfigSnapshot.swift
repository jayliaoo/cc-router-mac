import Foundation

/// 监听配置：网关 HTTP 服务绑定的地址与端口（design「数据设计」）。
public struct ListenConfig: Sendable, Equatable, Codable {
    public let address: String
    public let port: Int

    public init(address: String, port: Int) {
        self.address = address
        self.port = port
    }
}

/// 网关某一时刻的全部持久化状态（design「5.1」）：不可变值类型，
/// 由 ConfigStore 原子替换；请求入口取当下快照并全程使用，读路径无锁。
/// Codable 字段与 config.json 结构一一对应（design「数据设计」）。
public struct ConfigSnapshot: Sendable, Equatable, Codable {
    /// 配置文件结构版本，预留演进（design「数据设计」）。
    public let schemaVersion: Int
    public let gatewayEnabled: Bool
    public let listen: ListenConfig
    /// 数组顺序仅用于 UI 展示排序，路由不依赖顺序（design「数据设计」）。
    public let providers: [Provider]

    /// 首次启动（配置文件不存在）时的默认状态：主开关关闭，监听默认 `127.0.0.1:8317`。
    public static let `default` = ConfigSnapshot(
        gatewayEnabled: false,
        listen: ListenConfig(address: "127.0.0.1", port: 8317),
        providers: []
    )

    public init(
        schemaVersion: Int = 1,
        gatewayEnabled: Bool,
        listen: ListenConfig,
        providers: [Provider]
    ) {
        self.schemaVersion = schemaVersion
        self.gatewayEnabled = gatewayEnabled
        self.listen = listen
        self.providers = providers
    }
}

/// 保存时校验发现的一个问题。携带足够信息定位冲突项（provider / model），
/// 「可展示的错误信息」供 UI 标红（任务 06/07）消费。
public enum ConfigValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 模型列表留空（spec 用户故事 6）。
    case emptyModels(provider: Provider)
    /// 同一模型被多个 Provider 声明；与启用状态无关（spec 用户故事 5）。
    case modelClaimedByMultipleProviders(model: String, providers: [Provider])
    /// baseUrl 为空或不是合法 URL（design「数据设计」）。
    case invalidBaseUrl(provider: Provider)
    /// apiKey 为空（design「数据设计」）。
    case emptyApiKey(provider: Provider)
    /// Provider id 在配置内不唯一。
    case duplicateProviderId(id: UUID, providers: [Provider])

    public var description: String {
        switch self {
        case .emptyModels(let provider):
            "Provider「\(provider.name)」的模型列表不允许留空"
        case .modelClaimedByMultipleProviders(let model, let providers):
            "模型「\(model)」被多个 Provider 声明：\(providers.map(\.name).joined(separator: "、"))（校验与启用状态无关）"
        case .invalidBaseUrl(let provider):
            "Provider「\(provider.name)」的 baseUrl「\(provider.baseUrl)」为空或不是合法 URL"
        case .emptyApiKey(let provider):
            "Provider「\(provider.name)」的 apiKey 不允许为空"
        case .duplicateProviderId(let id, let providers):
            "Provider id 重复（\(id)）：\(providers.map(\.name).joined(separator: "、"))"
        }
    }
}

public extension ConfigSnapshot {
    /// 保存时校验（design「数据设计」）：一次性返回全部问题，供调用方整体标红展示。
    func validationErrors() -> [ConfigValidationError] {
        var errors: [ConfigValidationError] = []
        for provider in providers where provider.models.isEmpty {
            errors.append(.emptyModels(provider: provider))
        }
        for provider in providers where provider.apiKey.isEmpty {
            errors.append(.emptyApiKey(provider: provider))
        }
        for provider in providers where !Self.isValidBaseUrl(provider.baseUrl) {
            errors.append(.invalidBaseUrl(provider: provider))
        }

        var idClaims: [UUID: [Provider]] = [:]
        for provider in providers {
            idClaims[provider.id, default: []].append(provider)
        }
        for (id, claimants) in idClaims where claimants.count > 1 {
            errors.append(.duplicateProviderId(id: id, providers: claimants))
        }

        // 模型归属路由要求同一模型至多一个 Provider 声明；校验与启用状态无关
        // （spec 用户故事 5），因此按全部 Provider 统计声明方。
        var claimOrder: [String] = []
        var claims: [String: [Provider]] = [:]
        for provider in providers {
            for model in provider.models {
                var claimants = claims[model] ?? []
                if claimants.isEmpty { claimOrder.append(model) }
                // 同一 Provider 内部重复声明同一个模型不算跨 Provider 冲突。
                if !claimants.contains(where: { $0.id == provider.id }) {
                    claimants.append(provider)
                    claims[model] = claimants
                }
            }
        }
        for model in claimOrder {
            if let claimants = claims[model], claimants.count > 1 {
                errors.append(.modelClaimedByMultipleProviders(model: model, providers: claimants))
            }
        }
        return errors
    }

    /// baseUrl 须为非空的 http/https URL 且带主机名（上游都是 Anthropic 兼容 HTTP 端点）。
    private static func isValidBaseUrl(_ baseUrl: String) -> Bool {
        guard let url = URL(string: baseUrl), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }
}
