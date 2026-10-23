import AsyncHTTPClient
import Hummingbird
import NIOConcurrencyHelpers
import NIOCore
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

    private struct Running {
        let serviceGroup: ServiceGroup
        let runTask: Task<Void, Error>
        let httpClient: HTTPClient
    }

    private let configStore: ConfigStore
    private var running: Running?

    /// - Parameter configStore: 网关唯一配置来源（监听配置 + Provider 列表）。
    public init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    /// 启动网关监听并等待端口就绪。返回实际绑定的端口。
    /// 监听地址/端口取自配置快照；传 0 让系统分配临时端口。
    public func start() async throws -> Int {
        guard self.running == nil else { throw GatewayError.alreadyRunning }

        let snapshot = await configStore.current()
        let address = snapshot.listen.address
        let port = snapshot.listen.port

        let httpClient = HTTPClient(
            configuration: HTTPClient.Configuration(
                timeout: .init(connect: .seconds(10), read: .seconds(180))
            )
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
