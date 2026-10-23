import AsyncHTTPClient
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
        let gateway = GatewayServer(address: "127.0.0.1", port: 0, provider: provider)
        let gatewayPort = try await gateway.start()
        return GatewayFixture(
            upstream: upstream,
            gateway: gateway,
            gatewayPort: gatewayPort,
            client: HTTPClient(eventLoopGroupProvider: .singleton)
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

    @Test("鉴权头替换：客户端 key 不外泄，上游收到配置的 apiKey")
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
            #expect(firstValue(of: "x-api-key", in: received.headers) == "upstream-configured-key")
            #expect(firstValue(of: "authorization", in: received.headers) == nil)
            let headerValues = received.headers.map(\.value)
            #expect(!headerValues.contains("client-secret-key"))
            #expect(!headerValues.contains { $0.contains("client-bearer-token") })
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }
}
