import AsyncHTTPClient
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import NIOHTTP1

/// 次要端点（design 3.3）：`POST /v1/messages/count_tokens` 与 `GET /v1/models`。
/// 以 extension 形式放在独立文件，避免与 messages 转发管线（`proxy`）互相牵连。
extension GatewayRouter {
    /// `POST /v1/messages/count_tokens`：与 messages 同一路由（按 `model` 精确
    /// 匹配启用的 Provider），请求/响应原样转发。未命中模型仍 404 `model_not_found`
    /// （兜底只针对上游失败，不掩盖路由错误）。
    static func countTokens(
        _ request: Request,
        store: ConfigStore,
        using httpClient: HTTPClient
    ) async throws -> Response {
        let snapshot = await store.current()
        var request = request
        let body = try await request.collectBody(upTo: 64 * 1024 * 1024)

        let model = Self.requestedModel(in: body)
        guard let model,
            let provider = ModelRouter(providers: snapshot.providers).provider(forModel: model)
        else {
            return try Self.modelNotFound(model: model)
        }

        var upstream = HTTPClientRequest(url: Self.upstreamURL(baseUrl: provider.baseUrl, path: "/v1/messages/count_tokens"))
        upstream.method = .POST
        upstream.headers = forwardedHeaders(from: request.headers, apiKey: provider.apiKey)
        upstream.body = .bytes(body)
        let response: HTTPClientResponse
        do {
            response = try await httpClient.execute(upstream, deadline: .distantFuture)
        } catch {
            // 连接失败 → 兜底（design 3.3）：token 计数永不阻塞客户端会话。
            return try Self.countTokensFallback()
        }

        // 兜底优先于透传（design 3.3）：任何非 2xx 一律兜底，不透传上游错误。
        guard (200..<300).contains(response.status.code) else {
            return try Self.countTokensFallback()
        }

        // 响应方向与 messages 同一条规则：剔除逐跳头（connection /
        // transfer-encoding 等）后透传，避免上游连接语义错误影响客户端连接。
        let fields = Self.filteredResponseFields(from: response.headers)

        // count_tokens 的响应体是小 JSON，不流式：整体读入（上限 1MB）后
        // 原样回给客户端；读取失败/中断（含超上限）一律走兜底——2xx 但中途
        // 断开也不再让客户端收断连，token 计数永不阻塞客户端会话（spec 故事 8）。
        let responseBody: ByteBuffer
        do {
            responseBody = try await response.body.collect(upTo: Self.countTokensMaxBodyBytes)
        } catch {
            return try Self.countTokensFallback()
        }
        return Response(
            status: HTTPResponse.Status(code: Int(response.status.code)),
            headers: fields,
            body: .init(byteBuffer: responseBody)
        )
    }

    /// count_tokens 2xx 响应体整体读入的大小上限。
    static let countTokensMaxBodyBytes: Int = 1024 * 1024

    /// count_tokens 的失败兜底：`200` + `{"input_tokens": 0}`（spec 用户故事 8）。
    static func countTokensFallback() throws -> Response {
        var fields = HTTPFields()
        fields.append(HTTPField(name: .contentType, value: "application/json"))
        return Response(
            status: .ok,
            headers: fields,
            body: .init(byteBuffer: ByteBuffer(string: #"{"input_tokens":0}"#))
        )
    }

    /// `GET /v1/models`：本地聚合生成、不打上游（design 3.3）——启用 Provider
    /// 声明模型的并集，按名升序；`created_at` 为固定占位值，`data` 为空时
    /// `first_id`/`last_id` 为 `null`，`has_more` 恒 `false`。
    static func modelsList(store: ConfigStore) async throws -> Response {
        let snapshot = await store.current()
        let models = Set(snapshot.providers.filter(\.enabled).flatMap(\.models)).sorted()

        let entries: [[String: Any]] = models.map { model in
            [
                "id": model,
                "display_name": model,
                "created_at": "2025-01-01T00:00:00Z",
                "type": "model",
            ]
        }
        var first: Any = NSNull()
        if let firstModel = models.first { first = firstModel }
        var last: Any = NSNull()
        if let lastModel = models.last { last = lastModel }
        let payload: [String: Any] = [
            "data": entries,
            "first_id": first,
            "last_id": last,
            "has_more": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var fields = HTTPFields()
        fields.append(HTTPField(name: .contentType, value: "application/json"))
        return Response(status: .ok, headers: fields, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
