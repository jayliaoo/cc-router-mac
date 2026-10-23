import AsyncHTTPClient
import Foundation
import Hummingbird
import NIOCore
import NIOHTTP1
import Testing

@testable import CcRouterCore

/// Test seam: 真客户端 → 网关(Hummingbird) → 假上游(Hummingbird)，
/// 全部进程内、真 HTTP 往返。后续任务的网关测试复用本夹具。
struct GatewayFixture {
    let upstream: UpstreamStub
    let gateway: GatewayServer
    let gatewayPort: Int
    let client: HTTPClient

    static func start(upstreamResponse: UpstreamResponse) async throws -> GatewayFixture {
        let upstream = UpstreamStub(response: upstreamResponse)
        let upstreamPort = try await upstream.start()
        let provider = Provider(
            name: "假上游",
            baseUrl: "http://127.0.0.1:\(upstreamPort)",
            apiKey: "upstream-configured-key",
            models: ["claude-test-model"],
            enabled: true
        )
        let gateway = GatewayServer(configStore: makeConfigStore(providers: [provider], port: 0))
        let gatewayPort = try await gateway.start()
        return GatewayFixture(
            upstream: upstream,
            gateway: gateway,
            gatewayPort: gatewayPort,
            client: HTTPClient(eventLoopGroupProvider: .singleton)
        )
    }

    /// 网关配置来源：临时目录里的 ConfigStore 快照（不写盘，纯内存使用）。
    static func makeConfigStore(providers: [Provider], port: Int) -> ConfigStore {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-router-gateway-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.json")
        return ConfigStore(
            fileURL: fileURL,
            snapshot: ConfigSnapshot(
                gatewayEnabled: true,
                listen: ListenConfig(address: "127.0.0.1", port: port),
                providers: providers
            )
        )
    }

    func shutdown() async throws {
        try await self.client.shutdown()
        try await self.gateway.stop()
        try await self.upstream.stop()
    }

    /// POST to the gateway over real HTTP.
    func post(
        _ pathAndQuery: String,
        headers: [(name: String, value: String)] = [],
        body: String
    ) async throws -> (status: HTTPResponseStatus, headers: HTTPHeaders, body: String) {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(self.gatewayPort)\(pathAndQuery)")
        request.method = .POST
        var requestHeaders = HTTPHeaders()
        for (name, value) in headers {
            requestHeaders.replaceOrAdd(name: name, value: value)
        }
        request.headers = requestHeaders
        request.body = .bytes(ByteBuffer(string: body))
        let response = try await self.client.execute(request, timeout: .seconds(30))
        var buffer = try await response.body.collect(upTo: 64 * 1024 * 1024)
        let text = buffer.readString(length: buffer.readableBytes) ?? ""
        return (response.status, response.headers, text)
    }
}

func firstValue(of name: String, in headers: HTTPHeaders) -> String? {
    headers.first(where: { $0.name.lowercased() == name.lowercased() })?.value
}

func firstValue(of name: String, in headers: [(name: String, value: String)]) -> String? {
    headers.first(where: { $0.name.lowercased() == name.lowercased() })?.value
}

@Suite("网关端到端")
struct GatewayEndToEndTests {
    @Test("POST /v1/messages：响应体、状态码、响应头原样到达客户端")
    func forwardsResponseVerbatim() async throws {
        let upstreamBody = #"{"id":"msg_01","type":"message","role":"assistant","content":[]}"#
        let fixture = try await GatewayFixture.start(upstreamResponse: UpstreamResponse(
            status: .ok,
            headers: [
                ("content-type", "application/json"),
                ("x-request-id", "upstream-req-01"),
            ],
            body: upstreamBody
        ))
        do {
            let requestBody = #"{"model":"claude-test-model","messages":[{"role":"user","content":"hi"}]}"#
            let response = try await fixture.post(
                "/v1/messages",
                headers: [
                    ("content-type", "application/json"),
                    ("anthropic-version", "2023-06-01"),
                    ("user-agent", "test-client/1.0"),
                ],
                body: requestBody
            )

            #expect(response.status == .ok)
            #expect(response.body == upstreamBody)
            #expect(firstValue(of: "content-type", in: response.headers) == "application/json")
            #expect(firstValue(of: "x-request-id", in: response.headers) == "upstream-req-01")

            let received = await fixture.upstream.lastRequest()
            #expect(received.body == ByteBuffer(string: requestBody))
            #expect(firstValue(of: "anthropic-version", in: received.headers) == "2023-06-01")
            #expect(firstValue(of: "user-agent", in: received.headers) == "test-client/1.0")
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("鉴权头替换：客户端 key 不外泄，上游收到 Bearer 形式的 apiKey")
    func replacesAuthHeaders() async throws {
        let fixture = try await GatewayFixture.start(upstreamResponse: UpstreamResponse())
        do {
            _ = try await fixture.post(
                "/v1/messages",
                headers: [
                    ("content-type", "application/json"),
                    ("x-api-key", "client-secret-key"),
                    ("authorization", "Bearer client-bearer-token"),
                ],
                body: #"{"model":"claude-test-model","messages":[]}"#
            )

            let received = await fixture.upstream.lastRequest()
            #expect(firstValue(of: "authorization", in: received.headers) == "Bearer upstream-configured-key")
            #expect(firstValue(of: "x-api-key", in: received.headers) == nil)
            let headerValues = received.headers.map(\.value)
            #expect(!headerValues.contains("client-secret-key"))
            #expect(!headerValues.contains { $0.contains("client-bearer-token") })
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("同名多值请求头逐条透传：两条 anthropic-beta 都到达上游，鉴权头替换不受影响")
    func forwardsMultiValuedRequestHeaders() async throws {
        let upstreamBody = #"{"id":"msg_multi"}"#
        let fixture = try await GatewayFixture.start(upstreamResponse: UpstreamResponse(
            status: .ok,
            headers: [("content-type", "application/json")],
            body: upstreamBody
        ))
        do {
            // fixture.post 对同名头是替换语义，这里手工构造请求以发出两条同名头。
            var request = HTTPClientRequest(url: "http://127.0.0.1:\(fixture.gatewayPort)/v1/messages")
            request.method = .POST
            request.headers.add(name: "content-type", value: "application/json")
            request.headers.add(name: "anthropic-beta", value: "beta-one-2024-07-31")
            request.headers.add(name: "anthropic-beta", value: "beta-two-2024-07-15")
            request.headers.add(name: "x-api-key", value: "client-secret-key")
            request.body = .bytes(ByteBuffer(string: #"{"model":"claude-test-model","messages":[]}"#))
            let response = try await fixture.client.execute(request, timeout: .seconds(30))
            var buffer = try await response.body.collect(upTo: 1024 * 1024)
            #expect(response.status == .ok)
            #expect(String(buffer: buffer) == upstreamBody)

            let received = await fixture.upstream.lastRequest()
            let betaValues = received.headers
                .filter { $0.name.lowercased() == "anthropic-beta" }
                .map(\.value)
            #expect(betaValues == ["beta-one-2024-07-31", "beta-two-2024-07-15"])
            // 鉴权头仍是替换语义：客户端 key 不外泄。
            #expect(firstValue(of: "authorization", in: received.headers) == "Bearer upstream-configured-key")
            let headerValues = received.headers.map(\.value)
            #expect(!headerValues.contains("client-secret-key"))
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("POST /v1/messages?beta=true 与无查询参数同路由")
    func toleratesQueryParameters() async throws {
        let upstreamBody = #"{"id":"msg_beta"}"#
        let fixture = try await GatewayFixture.start(upstreamResponse: UpstreamResponse(
            status: .ok,
            headers: [("content-type", "application/json")],
            body: upstreamBody
        ))
        do {
            let response = try await fixture.post(
                "/v1/messages?beta=true",
                headers: [("content-type", "application/json")],
                body: #"{"model":"claude-test-model","messages":[]}"#
            )
            #expect(response.status == .ok)
            #expect(response.body == upstreamBody)

            let received = await fixture.upstream.lastRequest()
            #expect(received.method == "POST")
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("网关可重复起停，监听地址端口可指定")
    func serverCanStartStopRepeatedlyOnExplicitPort() async throws {
        let upstreamBody = #"{"id":"restart"}"#
        let upstream = UpstreamStub(response: UpstreamResponse(body: upstreamBody))
        let upstreamPort = try await upstream.start()
        let provider = Provider(
            name: "假上游",
            baseUrl: "http://127.0.0.1:\(upstreamPort)",
            apiKey: "upstream-configured-key",
            models: ["claude-test-model"],
            enabled: true
        )
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        do {
            // 先用端口 0 让系统分配一个实际端口
            let probe = GatewayServer(configStore: GatewayFixture.makeConfigStore(providers: [provider], port: 0))
            let port = try await probe.start()
            try await probe.stop()

            // 用显式端口重复起停同一个网关实例
            let gateway = GatewayServer(configStore: GatewayFixture.makeConfigStore(providers: [provider], port: port))
            let boundPort = try await gateway.start()
            #expect(boundPort == port)
            try await gateway.stop()
            try await gateway.start()

            var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)/v1/messages")
            request.method = .POST
            request.headers.replaceOrAdd(name: "content-type", value: "application/json")
            request.body = .bytes(ByteBuffer(string: #"{"model":"claude-test-model","messages":[]}"#))
            let response = try await client.execute(request, timeout: .seconds(30))
            var buffer = try await response.body.collect(upTo: 1024 * 1024)
            #expect(response.status == .ok)
            #expect(String(buffer: buffer) == upstreamBody)

            try await gateway.stop()
        } catch {
            try? await upstream.stop()
            try? await client.shutdown()
            throw error
        }
        try await upstream.stop()
        try await client.shutdown()
    }
}
