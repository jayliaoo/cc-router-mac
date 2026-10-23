import AsyncHTTPClient
import Hummingbird
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ServiceLifecycle

/// Minimal single-value promise used to wait for the server's bound port.
private final class PortPromise: @unchecked Sendable {
    private enum State {
        case blocked([CheckedContinuation<Int, Error>])
        case ready(Int)
        case failed(Error)
    }

    private let state = NIOLockedValueBox<State>(.blocked([]))

    func wait() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Int, Error>? = self.state.withLockedValue { state in
                switch state {
                case .blocked(var waiters):
                    waiters.append(continuation)
                    state = .blocked(waiters)
                    return nil
                case .ready(let port):
                    return .success(port)
                case .failed(let error):
                    return .failure(error)
                }
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func complete(_ port: Int) {
        let waiters = self.state.withLockedValue { state -> [CheckedContinuation<Int, Error>] in
            guard case .blocked(let waiters) = state else { return [] }
            state = .ready(port)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: port)
        }
    }

    func fail(_ error: Error) {
        let waiters = self.state.withLockedValue { state -> [CheckedContinuation<Int, Error>] in
            guard case .blocked(let waiters) = state else { return [] }
            state = .failed(error)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }
}

/// 网关 HTTP 服务：托管内嵌于进程内的 Hummingbird server（ADR-0002），
/// 路由与转发逻辑见 `GatewayRouter`（design「3 接口设计」）。配置来源是可
/// 热交换的 ConfigStore 快照（design 5.1）：监听地址/端口在 start 时取自快照，
/// 每个请求入口取当下快照并全程使用，运行中改配置对新请求立即生效、
/// 在途请求持有旧快照自然完成。
public actor GatewayServer {
    public enum GatewayError: Error {
        case alreadyRunning
    }

    /// 上游 connect 超时（design 2.3）：连接建立阶段最多等 10 秒。
    public static let upstreamConnectTimeout: TimeAmount = .seconds(10)
    /// 上游 read 空闲超时（design 2.3）：两次读到数据之间最多空转 180 秒，
    /// 覆盖长思考模型分钟级的首 token 延迟；流中持续有数据到达则永不触发。
    public static let upstreamReadIdleTimeout: TimeAmount = .seconds(180)

    /// 网关上游 HTTP 客户端的默认配置：connect 10s / read 空闲 180s、无资源总超时
    /// （不掐断超长流式会话，design 2.3）。测试可通过注入短超时配置验证其语义。
    public static func defaultUpstreamHTTPClientConfiguration() -> HTTPClient.Configuration {
        HTTPClient.Configuration(
            timeout: .init(connect: upstreamConnectTimeout, read: upstreamReadIdleTimeout)
        )
    }

    private struct Running {
        let serviceGroup: ServiceGroup
        let runTask: Task<Void, Error>
        let httpClient: HTTPClient
    }

    private let configStore: ConfigStore
    private let httpClientConfiguration: HTTPClient.Configuration
    private var running: Running?

    /// - Parameters:
    ///   - configStore: 网关唯一配置来源（监听配置 + Provider 列表）。
    ///   - httpClientConfiguration: 上游 HTTP 客户端配置；nil 时用默认超时配置
    ///     （connect 10s / read 空闲 180s，见 ``defaultUpstreamHTTPClientConfiguration``）。
    public init(
        configStore: ConfigStore,
        httpClientConfiguration: HTTPClient.Configuration? = nil
    ) {
        self.configStore = configStore
        self.httpClientConfiguration =
            httpClientConfiguration ?? Self.defaultUpstreamHTTPClientConfiguration()
    }

    /// 启动网关监听并等待端口就绪。返回实际绑定的端口。
    /// 监听地址/端口取自配置快照；传 0 让系统分配临时端口。
    public func start() async throws -> Int {
        guard self.running == nil else { throw GatewayError.alreadyRunning }

        let snapshot = await configStore.current()
        let address = snapshot.listen.address
        let port = snapshot.listen.port

        // 上游客户端跑在 NIO 而非 Network.framework 的事件循环上：macOS 的
        // AHC 默认走 NIOTS/NW 路径，实测其不遵守 connect timeout（SYN 挂死的
        // 远端要等 ~15.5s 的系统 TCP 重试上限才失败，见任务 04 超时测试）；
        // design 2.3 要求 connect 10s 转写 502，NIO 路径的 connectTimeout
        // 语义才是准的。shared 组是进程级单例，AHC shutdown 不会关掉它。
        let httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            configuration: self.httpClientConfiguration
        )
        let store = self.configStore
        let router = Router(context: BasicRequestContext.self)
        GatewayRouter.registerRoutes(on: router, configStore: store, httpClient: httpClient)

        let portPromise = PortPromise()
        let app = Application(
            router: router,
            configuration: ApplicationConfiguration(address: .hostname(address, port: port)),
            onServerRunning: { channel in
                portPromise.complete(channel.localAddress?.port ?? port)
            }
        )
        let serviceGroup = ServiceGroup(services: [app], logger: app.logger)
        let runTask = Task<Void, Error> {
            do {
                try await serviceGroup.run()
            } catch {
                portPromise.fail(error)
                throw error
            }
        }
        do {
            let boundPort = try await portPromise.wait()
            self.running = Running(serviceGroup: serviceGroup, runTask: runTask, httpClient: httpClient)
            return boundPort
        } catch {
            _ = try? await runTask.value
            try? await httpClient.shutdown()
            throw error
        }
    }

    /// 停止网关监听；在途请求自然走完（design 5.3）。
    public func stop() async throws {
        guard let running = self.running else { return }
        self.running = nil
        await running.serviceGroup.triggerGracefulShutdown()
        // run 失败（如端口占用）已在 start 时上报，stop 保持幂等。
        do {
            try await running.runTask.value
        } catch let error as CancellationError {
            throw error
        } catch {}
        try await running.httpClient.shutdown()
    }
}
