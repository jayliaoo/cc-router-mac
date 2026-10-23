import AsyncHTTPClient
import Foundation
import Hummingbird
import NIOCore
import NIOHTTP1
import Testing

@testable import CcRouterCore

/// 多上游端到端夹具：N 个假上游（UpstreamStub）+ 网关 + 真 HTTP 客户端，
/// 复用任务 01 的 seam 夹具，全部进程内、真 HTTP 往返。
struct RoutingFixture {
    struct Upstream {
        let stub: UpstreamStub
        let port: Int

        var baseUrl: String { "http://127.0.0.1:\(self.port)" }
    }

    let upstreams: [Upstream]
    let configStore: ConfigStore
    let gateway: GatewayServer
    let gatewayPort: Int
    let client: HTTPClient

    /// 每个 spec 启动一个假上游，并生成对应的 Provider（第 i 个 spec 的模型归属第 i 个上游）。
    static func start(
        providerSpecs: [(response: UpstreamResponse, models: [String], enabled: Bool)],
        httpClientConfiguration: HTTPClient.Configuration? = nil
    ) async throws -> RoutingFixture {
        var upstreams: [Upstream] = []
        var providers: [Provider] = []
        for (index, spec) in providerSpecs.enumerated() {
            let stub = UpstreamStub(response: spec.response)
            let port = try await stub.start()
            upstreams.append(Upstream(stub: stub, port: port))
            providers.append(Provider(
                name: "上游\(index)",
                baseUrl: "http://127.0.0.1:\(port)",
                apiKey: "upstream-key-\(index)",
                models: spec.models,
                enabled: spec.enabled
            ))
        }
        return try await self.start(
            providers: providers,
            upstreams: upstreams,
            httpClientConfiguration: httpClientConfiguration
        )
    }

    /// 直接给定 Provider 列表（无上游或外部构造 baseUrl 时用）。
    static func start(
        providers: [Provider],
        upstreams: [Upstream] = [],
        httpClientConfiguration: HTTPClient.Configuration? = nil
    ) async throws -> RoutingFixture {
        let configStore = GatewayFixture.makeConfigStore(providers: providers, port: 0)
        let gateway = GatewayServer(
            configStore: configStore,
            httpClientConfiguration: httpClientConfiguration
        )
        let gatewayPort = try await gateway.start()
        return RoutingFixture(
            upstreams: upstreams,
            configStore: configStore,
            gateway: gateway,
            gatewayPort: gatewayPort,
            client: HTTPClient(eventLoopGroupProvider: .singleton)
        )
    }

    /// 一个「无监听端口」：起真 server 拿系统分配的端口后立刻停掉。
    static func unusedPort() async throws -> Int {
        let runner = HttpServerRunner(
            router: Router(context: BasicRequestContext.self),
            address: "127.0.0.1",
            port: 0
        )
        let port = try await runner.start()
        try await runner.stop()
        return port
    }

    func shutdown() async throws {
        try await self.client.shutdown()
        try await self.gateway.stop()
        for upstream in self.upstreams {
            try await upstream.stub.stop()
        }
    }

    /// 发一个真 HTTP 请求到网关。
    func request(
        _ method: HTTPMethod,
        _ pathAndQuery: String,
        body: String = ""
    ) async throws -> (status: HTTPResponseStatus, body: String) {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(self.gatewayPort)\(pathAndQuery)")
        request.method = method
        request.headers.replaceOrAdd(name: "content-type", value: "application/json")
        if !body.isEmpty {
            request.body = .bytes(ByteBuffer(string: body))
        }
        let response = try await self.client.execute(request, timeout: .seconds(30))
        var buffer = try await response.body.collect(upTo: 64 * 1024 * 1024)
        let text = buffer.readString(length: buffer.readableBytes) ?? ""
        return (response.status, text)
    }

    /// POST /v1/messages，请求体只带指定 model。
    func postMessages(model: String) async throws -> (status: HTTPResponseStatus, body: String) {
        try await self.request(.POST, "/v1/messages", body: #"{"model":"\#(model)","messages":[]}"#)
    }

    /// POST /v1/messages，返回未消费的流式响应（body 由调用方逐段读取），
    /// 用于断言 SSE 的渐进到达与连接终止行为（任务 04 seam 约定）。
    func streamMessages(
        model: String,
        timeout: TimeAmount = .seconds(30)
    ) async throws -> HTTPClientResponse {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(self.gatewayPort)/v1/messages")
        request.method = .POST
        request.headers.replaceOrAdd(name: "content-type", value: "application/json")
        request.body = .bytes(ByteBuffer(string: #"{"model":"\#(model)","messages":[]}"#))
        return try await self.client.execute(request, timeout: timeout)
    }
}

/// 解析 Anthropic 错误体 `{"type":"error","error":{"type":..,"message":..}}`；
/// 形状不符（字段缺失或顶层 type 不是 "error"）返回 nil。
func anthropicError(from body: String) -> (type: String, message: String)? {
    guard let data = body.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["type"] as? String == "error",
          let error = object["error"] as? [String: Any],
          let type = error["type"] as? String,
          let message = error["message"] as? String
    else { return nil }
    return (type, message)
}

@Suite("模型归属路由端到端")
struct ModelRoutingEndToEndTests {
    @Test("两个启用的 Provider 各声明不同模型：请求按 model 路由到正确上游，请求体原样到达")
    func routesByModelOwnership() async throws {
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (UpstreamResponse(body: #"{"id":"from-a"}"#), ["model-a"], true),
            (UpstreamResponse(body: #"{"id":"from-b"}"#), ["model-b"], true),
        ])
        do {
            let bodyA = #"{"model":"model-a","messages":[{"role":"user","content":"hi"}],"max_tokens":10}"#
            let responseA = try await fixture.request(.POST, "/v1/messages", body: bodyA)
            #expect(responseA.status == .ok)
            #expect(responseA.body == #"{"id":"from-a"}"#)

            let receivedA = await fixture.upstreams[0].stub.lastRequest()
            #expect(receivedA.body == ByteBuffer(string: bodyA))
            #expect(firstValue(of: "x-api-key", in: receivedA.headers) == "upstream-key-0")

            let responseB = try await fixture.postMessages(model: "model-b")
            #expect(responseB.status == .ok)
            #expect(responseB.body == #"{"id":"from-b"}"#)
            #expect(firstValue(of: "x-api-key", in: await fixture.upstreams[1].stub.lastRequest().headers) == "upstream-key-1")
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("model 只被禁用的 Provider 声明 → 404 model_not_found（Anthropic 错误体）")
    func disabledProviderYieldsModelNotFound() async throws {
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (UpstreamResponse(body: #"{"id":"from-a"}"#), ["model-a"], false),
        ])
        do {
            let response = try await fixture.postMessages(model: "model-a")
            #expect(response.status == .notFound)
            let error = anthropicError(from: response.body)
            #expect(error?.type == "model_not_found")
            #expect(error?.message.isEmpty == false)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("上游返回 401/429/500：状态码与错误体原样到达客户端")
    func passesUpstreamErrorsThrough() async throws {
        let error401 = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        let error429 = #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#
        let error500 = #"{"type":"error","error":{"type":"api_error","message":"upstream boom"}}"#
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (UpstreamResponse(status: .unauthorized, body: error401), ["model-e401"], true),
            (UpstreamResponse(status: .tooManyRequests, body: error429), ["model-e429"], true),
            (UpstreamResponse(status: .internalServerError, body: error500), ["model-e500"], true),
        ])
        do {
            let e401 = try await fixture.postMessages(model: "model-e401")
            #expect(e401.status == .unauthorized)
            #expect(e401.body == error401)

            let e429 = try await fixture.postMessages(model: "model-e429")
            #expect(e429.status == .tooManyRequests)
            #expect(e429.body == error429)

            let e500 = try await fixture.postMessages(model: "model-e500")
            #expect(e500.status == .internalServerError)
            #expect(e500.body == error500)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("上游不可达（无监听端口）→ 502 api_error（Anthropic 错误体）")
    func unreachableUpstreamYields502ApiError() async throws {
        let deadPort = try await RoutingFixture.unusedPort()
        let provider = Provider(
            name: "死上游",
            baseUrl: "http://127.0.0.1:\(deadPort)",
            apiKey: "upstream-key-dead",
            models: ["model-dead"],
            enabled: true
        )
        let fixture = try await RoutingFixture.start(providers: [provider])
        do {
            let response = try await fixture.postMessages(model: "model-dead")
            #expect(response.status == .badGateway)
            let error = anthropicError(from: response.body)
            #expect(error?.type == "api_error")
            #expect(error?.message.isEmpty == false)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("baseUrl 带尾斜杠：规范化拼接，上游收到单斜杠路径（不出现 //v1/messages）")
    func trailingSlashBaseUrlNormalizedForMessages() async throws {
        let stub = UpstreamStub(response: UpstreamResponse(body: #"{"id":"from-slash"}"#))
        let upstreamPort = try await stub.start()
        let provider = Provider(
            name: "尾斜杠上游",
            baseUrl: "http://127.0.0.1:\(upstreamPort)/",
            apiKey: "slash-key",
            models: ["model-slash"],
            enabled: true
        )
        let fixture = try await RoutingFixture.start(
            providers: [provider],
            upstreams: [RoutingFixture.Upstream(stub: stub, port: upstreamPort)]
        )
        do {
            let response = try await fixture.postMessages(model: "model-slash")
            #expect(response.status == .ok)
            #expect(response.body == #"{"id":"from-slash"}"#)

            let received = await fixture.upstreams[0].stub.lastRequest()
            #expect(received.uri == "/v1/messages")
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("未识别路径 → 404 not_found_error（Anthropic 错误体）")
    func unrecognizedPathYieldsNotFoundError() async throws {
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (UpstreamResponse(body: #"{"id":"from-a"}"#), ["model-a"], true),
        ])
        do {
            let post = try await fixture.request(.POST, "/v1/other", body: #"{"model":"model-a"}"#)
            #expect(post.status == .notFound)
            #expect(anthropicError(from: post.body)?.type == "not_found_error")

            let get = try await fixture.request(.GET, "/v1/other")
            #expect(get.status == .notFound)
            #expect(anthropicError(from: get.body)?.type == "not_found_error")
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("运行中经 ConfigStore 换快照：后续请求立即按新配置路由，在途请求不受影响")
    func hotSwapTakesEffectImmediately() async throws {
        let oldBody = #"{"id":"from-old-slow"}"#
        let newBody = #"{"id":"from-new"}"#
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (UpstreamResponse(body: oldBody, delay: .seconds(1)), ["model-swap"], true),
            (UpstreamResponse(body: newBody), ["model-b"], true),
        ])
        do {
            // 在途请求：发出后等它确实被旧上游接收，再换快照。
            async let inFlight = fixture.postMessages(model: "model-swap")
            _ = await fixture.upstreams[0].stub.lastRequest()

            // 换快照：model-swap 改由第二个上游声明；保存时校验通过。
            let current = await fixture.configStore.current()
            let old = current.providers[0]
            let kept = current.providers[1]
            let newSnapshot = ConfigSnapshot(
                gatewayEnabled: current.gatewayEnabled,
                listen: current.listen,
                providers: [
                    Provider(
                        id: old.id,
                        name: old.name,
                        baseUrl: old.baseUrl,
                        apiKey: old.apiKey,
                        models: ["model-retired"],
                        enabled: false
                    ),
                    Provider(
                        id: kept.id,
                        name: kept.name,
                        baseUrl: kept.baseUrl,
                        apiKey: kept.apiKey,
                        models: ["model-b", "model-swap"],
                        enabled: true
                    ),
                ]
            )
            try await fixture.configStore.save(newSnapshot)

            // 后续请求立即按新配置路由。
            let newResponse = try await fixture.postMessages(model: "model-swap")
            #expect(newResponse.status == .ok)
            #expect(newResponse.body == newBody)

            // 在途请求不受影响：仍拿到旧上游的响应。
            let oldResponse = try await inFlight
            #expect(oldResponse.status == .ok)
            #expect(oldResponse.body == oldBody)

            // 旧上游只收到过换快照前的那一个请求；新上游只收到换快照后的那一个。
            #expect(fixture.upstreams[0].stub.requestCount() == 1)
            #expect(fixture.upstreams[1].stub.requestCount() == 1)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }
}
