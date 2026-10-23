import AsyncHTTPClient
import Hummingbird
import HTTPTypes
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
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
/// 把 `/v1` 路由转发给配置的 Provider 上游（本阶段为写死的单 Provider 配置）。
public actor GatewayServer {
    public enum GatewayError: Error {
        case alreadyRunning
    }

    private struct Running {
        let serviceGroup: ServiceGroup
        let runTask: Task<Void, Error>
        let httpClient: HTTPClient
    }

    private let address: String
    private let port: Int
    private let provider: Provider
    private var running: Running?

    /// - Parameters:
    ///   - address: 监听地址，默认 `127.0.0.1`（spec：默认仅本机可达）
    ///   - port: 监听端口，默认 8317；传 0 让系统分配临时端口（`start()` 返回实际端口）
    public init(address: String = "127.0.0.1", port: Int = 8317, provider: Provider) {
        self.address = address
        self.port = port
        self.provider = provider
    }

    /// 启动网关监听并等待端口就绪。返回实际绑定的端口。
    public func start() async throws -> Int {
        guard self.running == nil else { throw GatewayError.alreadyRunning }

        let httpClient = HTTPClient(
            configuration: HTTPClient.Configuration(
                timeout: .init(connect: .seconds(10), read: .seconds(180))
            )
        )
        let provider = self.provider
        let router = Router(context: BasicRequestContext.self)
        router.post("v1/messages") { request, _ -> Response in
            try await Self.proxy(request, to: provider, using: httpClient)
        }

        let portPromise = PortPromise()
        let app = Application(
            router: router,
            configuration: ApplicationConfiguration(address: .hostname(self.address, port: self.port)),
            onServerRunning: { channel in
                portPromise.complete(channel.localAddress?.port ?? self.port)
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

    /// 把客户端请求转发给命中 Provider 的上游。
    private static func proxy(_ request: Request, to provider: Provider, using httpClient: HTTPClient) async throws -> Response {
        var request = request
        let body = try await request.collectBody(upTo: 64 * 1024 * 1024)

        var upstream = HTTPClientRequest(url: provider.baseUrl + "/v1/messages")
        upstream.method = .POST
        upstream.headers = forwardedHeaders(from: request.headers, apiKey: provider.apiKey)
        upstream.body = .bytes(body)
        let response = try await httpClient.execute(upstream, deadline: .distantFuture)

        var fields = HTTPFields()
        for (name, value) in response.headers {
            guard let name = HTTPField.Name(name) else { continue }
            fields.append(.init(name: name, value: value))
        }
        return Response(
            status: HTTPResponse.Status(code: Int(response.status.code)),
            headers: fields,
            body: .init(asyncSequence: response.body)
        )
    }

    /// 转发请求头：原样透传，仅鉴权头（`x-api-key` / `authorization`）替换为
    /// 命中 Provider 的 apiKey（客户端自己的 key 不外泄），并剔除逐跳头与
    /// 由 HTTP 客户端自行管理的头。
    private static func forwardedHeaders(from headers: HTTPFields, apiKey: String) -> HTTPHeaders {
        var forwarded = HTTPHeaders()
        for field in headers {
            let name = field.name.description
            let lowered = name.lowercased()
            guard !Self.hopByHopNames.contains(lowered), lowered != "x-api-key", lowered != "authorization" else { continue }
            forwarded.replaceOrAdd(name: name, value: field.value)
        }
        forwarded.replaceOrAdd(name: "x-api-key", value: apiKey)
        return forwarded
    }

    private static let hopByHopNames: Set<String> = [
        "connection",
        "content-length",
        "host",
        "keep-alive",
        "proxy-connection",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ]
}
