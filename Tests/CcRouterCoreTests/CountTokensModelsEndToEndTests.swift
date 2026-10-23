import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import CcRouterCore

/// 任务 05 端到端：`POST /v1/messages/count_tokens` 透传与失败兜底、
/// `GET /v1/models` 聚合。复用任务 03 的 RoutingFixture（HTTP 端到端 seam）。
@Suite("count_tokens 与 models 端到端")
struct CountTokensModelsEndToEndTests {
    @Test("count_tokens 按 model 路由到正确上游、响应原样透传（含 ?beta=true 变体）")
    func countTokensRoutesAndPassesThrough() async throws {
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (UpstreamResponse(body: #"{"input_tokens":11}"#), ["model-a"], true),
            (UpstreamResponse(body: #"{"input_tokens":22}"#), ["model-b"], true),
        ])
        do {
            let responseA = try await fixture.request(
                .POST, "/v1/messages/count_tokens",
                body: #"{"model":"model-a","messages":[{"role":"user","content":"hi"}]}"#
            )
            #expect(responseA.status == .ok)
            #expect(responseA.body == #"{"input_tokens":11}"#)

            // ?beta=true 查询参数变体与无参数同路由、同透传。
            let responseB = try await fixture.request(
                .POST, "/v1/messages/count_tokens?beta=true",
                body: #"{"model":"model-b","messages":[]}"#
            )
            #expect(responseB.status == .ok)
            #expect(responseB.body == #"{"input_tokens":22}"#)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("count_tokens 请求原样到达命中的上游：路径、请求体不改写、鉴权头替换")
    func countTokensRequestReachesUpstreamIntact() async throws {
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (UpstreamResponse(body: #"{"input_tokens":11}"#), ["model-a"], true),
        ])
        do {
            let bodyA = #"{"model":"model-a","messages":[{"role":"user","content":"hi"}],"stream":false}"#
            let response = try await fixture.request(.POST, "/v1/messages/count_tokens?beta=true", body: bodyA)
            #expect(response.status == .ok)

            let received = await fixture.upstreams[0].stub.lastRequest()
            #expect(received.method == "POST")
            #expect(received.uri == "/v1/messages/count_tokens")
            #expect(received.body == ByteBuffer(string: bodyA))
            #expect(firstValue(of: "x-api-key", in: received.headers) == "upstream-key-0")
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("count_tokens 上游连接失败 → 200 与 {\"input_tokens\": 0} 兜底")
    func countTokensConnectFailureFallsBackToZero() async throws {
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
            let response = try await fixture.request(
                .POST, "/v1/messages/count_tokens",
                body: #"{"model":"model-dead","messages":[]}"#
            )
            #expect(response.status == .ok)
            #expect(response.body == #"{"input_tokens":0}"#)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("count_tokens 上游返回 401/429/500（非 2xx）→ 200 与 {\"input_tokens\": 0} 兜底")
    func countTokensNon2xxUpstreamFallsBackToZero() async throws {
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (UpstreamResponse(status: .unauthorized, body: #"{"type":"error"}"#), ["model-e401"], true),
            (UpstreamResponse(status: .tooManyRequests, body: #"{"type":"error"}"#), ["model-e429"], true),
            (UpstreamResponse(status: .internalServerError, body: #"{"type":"error"}"#), ["model-e500"], true),
        ])
        do {
            for model in ["model-e401", "model-e429", "model-e500"] {
                let response = try await fixture.request(
                    .POST, "/v1/messages/count_tokens",
                    body: #"{"model":"\#(model)","messages":[]}"#
                )
                #expect(response.status == .ok)
                #expect(response.body == #"{"input_tokens":0}"#)
            }
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("count_tokens 未命中模型 → 404 model_not_found（兜底不吞路由错误）")
    func countTokensModelNotFoundStill404() async throws {
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (UpstreamResponse(body: #"{"input_tokens":11}"#), ["model-a"], false),
        ])
        do {
            // 只被禁用 Provider 声明的模型，与无任何 Provider 声明一样未命中。
            let response = try await fixture.request(
                .POST, "/v1/messages/count_tokens",
                body: #"{"model":"model-a","messages":[]}"#
            )
            #expect(response.status == .notFound)
            let error = anthropicError(from: response.body)
            #expect(error?.type == "model_not_found")
            #expect(error?.message.isEmpty == false)

            let unknown = try await fixture.request(
                .POST, "/v1/messages/count_tokens?beta=true",
                body: #"{"model":"model-nobody","messages":[]}"#
            )
            #expect(unknown.status == .notFound)
            #expect(anthropicError(from: unknown.body)?.type == "model_not_found")

            // 未转发：假上游没有收到任何请求。
            #expect(fixture.upstreams[0].stub.requestCount() == 0)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("GET /v1/models 聚合启用 Provider 的模型（按名升序、字段形态、禁用不出现、?limit=1000 变体）")
    func modelsAggregatesEnabledProviders() async throws {
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (UpstreamResponse(), ["zeta-model", "alpha-model"], true),
            (UpstreamResponse(), ["mid-model"], true),
            (UpstreamResponse(), ["disabled-model"], false),
        ])
        do {
            let response = try await fixture.request(.GET, "/v1/models")
            #expect(response.status == .ok)
            let object = try Self.jsonObject(response.body)
            let data = try #require(object["data"] as? [[String: Any]])
            #expect(data.map { $0["id"] as? String } == ["alpha-model", "mid-model", "zeta-model"])
            #expect(data.map { $0["display_name"] as? String } == ["alpha-model", "mid-model", "zeta-model"])
            #expect(data.allSatisfy { ($0["created_at"] as? String) == "2025-01-01T00:00:00Z" })
            #expect(data.allSatisfy { ($0["type"] as? String) == "model" })
            #expect(object["first_id"] as? String == "alpha-model")
            #expect(object["last_id"] as? String == "zeta-model")
            #expect(object["has_more"] as? Bool == false)

            // ?limit=1000 查询参数变体与无参数同响应。
            let withQuery = try await fixture.request(.GET, "/v1/models?limit=1000")
            #expect(withQuery.status == .ok)
            #expect(withQuery.body == response.body)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    /// 把 JSON 文本解析成顶层对象，供端到端断言消费。
    private static func jsonObject(_ body: String) throws -> [String: Any] {
        let data = try #require(body.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("全部 Provider 禁用 → models 空响应：data 为 []、first_id/last_id 为 null、has_more 为 false")
    func allProvidersDisabledYieldsEmptyModels() async throws {
        let fixture = try await RoutingFixture.start(providers: [
            Provider(
                name: "禁用上游",
                baseUrl: "http://127.0.0.1:9",
                apiKey: "disabled-key",
                models: ["model-x"],
                enabled: false
            ),
        ])
        do {
            let response = try await fixture.request(.GET, "/v1/models")
            #expect(response.status == .ok)
            let object = try Self.jsonObject(response.body)
            #expect((object["data"] as? [Any])?.isEmpty == true)
            #expect(object["first_id"] is NSNull)
            #expect(object["last_id"] is NSNull)
            #expect(object["has_more"] as? Bool == false)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }
}
