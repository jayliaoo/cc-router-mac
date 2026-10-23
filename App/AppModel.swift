import CcRouterCore
import Foundation
import Observation

/// 设置窗口一次「保存」的结果（AppModel → 设置 UI，任务 07）。
enum SettingsSaveOutcome {
    /// 已落盘并热生效；监听地址/端口变更时已用新配置重启 listener。
    case saved
    /// ConfigStore 校验拒绝：未落盘、内存快照未变；`errors` 供 UI 一次性标红定位。
    case rejected([ConfigValidationError])
    /// 落盘 IO 失败：配置与内存快照未变。
    case failed(String)
}

/// App 壳的生命周期编排（design「2.2 App 生命周期」+「5.3 监听生命周期」）：
/// 唯一职责是把 popover 的开关动作翻译为 ConfigStore.save（持久化 + 热生效）
/// 与 GatewayServer start/stop；网关与路由逻辑全部在核心包内。
///
/// - 启动：`bootstrap` 读取默认位置配置；上次主开关为开 → 自动 start。
/// - 主开关 on → start 成功后落盘 `gatewayEnabled: true`；失败（如端口被占用）→
///   UI 回落 off、给出明确错误、落盘 `gatewayEnabled: false`（盘上状态与实际一致）。
/// - 主开关 off → 停止接受新连接（在途自然走完），落盘 false。
/// - provider 开关 → 经 `ConfigStore.save` 换快照，热生效、在途不受影响。
@MainActor
@Observable
final class AppModel {
    private let configStore: ConfigStore
    private let server: GatewayServer

    /// 当下配置快照的 UI 侧镜像；任何修改都经 `configStore.save` 后回填。
    private(set) var snapshot: ConfigSnapshot = .default
    /// 网关是否正在监听（主开关的显示态）。
    private(set) var gatewayRunning = false
    /// 主开关启动失败等需要向用户明示的错误；nil 表示无异常。
    private(set) var errorMessage: String?
    private var bootstrapped = false

    init(configStore: ConfigStore) {
        self.configStore = configStore
        self.server = GatewayServer(configStore: configStore)
        Task { await self.bootstrap() }
    }

    /// 真实 app 的入口：读默认位置 config.json（不存在视为首次启动，见 ConfigStore.load）。
    /// 文件损坏等读取失败 → 退回默认快照并显示错误，后续保存会重写该文件。
    static func live() -> AppModel {
        let fileURL: URL
        do {
            fileURL = try ConfigStore.defaultFileURL()
        } catch {
            return AppModel(
                configStore: ConfigStore(
                    fileURL: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Application Support/cc-router-mac/config.json")
                )
            ).withBootstrapError("无法定位配置文件位置：\(error.localizedDescription)")
        }
        do {
            return AppModel(configStore: try ConfigStore.load(from: fileURL))
        } catch {
            return AppModel(configStore: ConfigStore(fileURL: fileURL))
                .withBootstrapError("配置读取失败，已回退默认配置：\(error.localizedDescription)")
        }
    }

    /// 启动恢复（spec 19）：上次主开关为开 → 本次自动起网关；
    /// 起不来（如端口被占用）→ UI 报错且主开关回落 off。
    private func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        snapshot = await configStore.current()
        if snapshot.gatewayEnabled {
            await setGateway(true)
        }
    }

    // MARK: 主开关

    func setGateway(_ on: Bool) async {
        if on {
            await enableGateway()
        } else {
            await disableGateway()
        }
    }

    private func enableGateway() async {
        do {
            _ = try await server.start()
            gatewayRunning = true
            errorMessage = nil
            await persist(gatewayEnabled: true)
        } catch {
            // design 5.3：启动失败（端口被占用等）→ UI 明确报错、主开关回落 off，
            // 并让盘上状态与实际一致（回落即持久化为关）。
            gatewayRunning = false
            errorMessage = Self.startFailureMessage(
                listen: snapshot.listen, error: error
            )
            await persist(gatewayEnabled: false)
        }
    }

    private func disableGateway() async {
        gatewayRunning = false
        // stop 幂等；在途请求自然走完（design 5.3）。
        do {
            try await server.stop()
        } catch {
            errorMessage = "网关停止失败：\(error.localizedDescription)"
        }
        await persist(gatewayEnabled: false)
    }

    private static func startFailureMessage(listen: ListenConfig, error: Error) -> String {
        let reason = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
        return "网关启动失败：无法监听 \(listen.address):\(String(listen.port))（端口可能已被占用）——\(reason)"
    }

    // MARK: Provider 启用开关

    func setProvider(_ providerID: UUID, enabled: Bool) async {
        guard let index = snapshot.providers.firstIndex(where: { $0.id == providerID }) else { return }
        var providers = snapshot.providers
        providers[index] = providers[index].settingEnabled(enabled)
        let newSnapshot = snapshot.withProviders(providers)
        do {
            try await configStore.save(newSnapshot)
            snapshot = newSnapshot
            errorMessage = nil
        } catch let error as ConfigStore.SaveError {
            errorMessage = "配置保存失败：\n" + error.errors.map(\.description).joined(separator: "\n")
        } catch {
            errorMessage = "配置保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: 设置窗口（任务 07）

    /// 设置窗口的统一保存入口：Provider 增删改排序与监听地址端口都走这里。
    /// 校验拒绝 → 返回 `.rejected`（配置与内存快照不变）；校验通过 → 落盘热生效；
    /// 监听配置有变 → 用新地址重启 listener，起不来 → 报错 + 主开关回落 off
    /// （design 5.3，沿用任务 06 的报错通道）。
    func applySettings(providers: [Provider], listen: ListenConfig) async -> SettingsSaveOutcome {
        let listenChanged = listen != snapshot.listen
        let providersChanged = providers != snapshot.providers
        guard listenChanged || providersChanged else { return .saved }

        let newSnapshot = ConfigSnapshot(
            schemaVersion: snapshot.schemaVersion,
            gatewayEnabled: snapshot.gatewayEnabled,
            listen: listen,
            providers: providers
        )
        do {
            try await configStore.save(newSnapshot)
        } catch let error as ConfigStore.SaveError {
            return .rejected(error.errors)
        } catch {
            let message = "配置保存失败：\(error.localizedDescription)"
            errorMessage = message
            return .failed(message)
        }
        snapshot = newSnapshot
        errorMessage = nil
        if listenChanged {
            await restartListener()
        }
        return .saved
    }

    /// 监听地址/端口变更后的重启（design 5.3）：旧 listener 停止后在途请求自然走完，
    /// 新请求按新地址走新 listener。新端口起不来（如被占用）→ 明确报错 +
    /// 主开关回落 off，并让盘上状态与实际一致。
    private func restartListener() async {
        guard gatewayRunning else { return }
        do {
            try await server.stop()
        } catch {
            // stop 幂等失败不妨碍随后以新配置重新 start 的尝试，先行记录。
            errorMessage = "网关停止失败：\(error.localizedDescription)"
        }
        do {
            _ = try await server.start()
        } catch {
            gatewayRunning = false
            errorMessage = Self.startFailureMessage(listen: snapshot.listen, error: error)
            await persist(gatewayEnabled: false)
        }
    }

    // MARK: 持久化

    /// 开关变更经 ConfigStore.save 落盘并热生效（design 5.1）；
    /// 只改主开关位，其余字段保持当下快照。
    private func persist(gatewayEnabled: Bool) async {
        let newSnapshot = snapshot.withGatewayEnabled(gatewayEnabled)
        do {
            try await configStore.save(newSnapshot)
            snapshot = newSnapshot
        } catch {
            errorMessage = "配置保存失败：\(error.localizedDescription)"
        }
    }

    private func withBootstrapError(_ message: String) -> AppModel {
        errorMessage = message
        return self
    }
}

// MARK: - 快照便捷变换（纯值类型改写，非核心逻辑）

private extension ConfigSnapshot {
    func withGatewayEnabled(_ enabled: Bool) -> ConfigSnapshot {
        ConfigSnapshot(
            schemaVersion: schemaVersion,
            gatewayEnabled: enabled,
            listen: listen,
            providers: providers
        )
    }

    func withProviders(_ providers: [Provider]) -> ConfigSnapshot {
        ConfigSnapshot(
            schemaVersion: schemaVersion,
            gatewayEnabled: gatewayEnabled,
            listen: listen,
            providers: providers
        )
    }
}

private extension Provider {
    func settingEnabled(_ enabled: Bool) -> Provider {
        Provider(
            id: id,
            name: name,
            baseUrl: baseUrl,
            apiKey: apiKey,
            models: models,
            enabled: enabled
        )
    }
}
