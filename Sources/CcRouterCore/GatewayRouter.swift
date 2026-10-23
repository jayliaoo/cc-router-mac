import AsyncHTTPClient
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import NIOHTTP1

/// 网关路由模块（design「3 接口设计」）：把 Hummingbird Router 组装成网关的对外端点。
/// 端点：`POST /v1/messages`（转发）、`POST /v1/messages/count_tokens`（透传 + 失败兜底）、
/// `GET /v1/models`（本地聚合）——次要端点见 `SecondaryEndpoints.swift`；
/// 其余一切路径/方法组合 404 `not_found_error`。
enum GatewayRouter {
    /// 在给定的 Hummingbird Router 上注册网关全部端点。
    /// 白名单守卫加在最前（design 3.1 生命周期第一步）：白名单外的请求
    /// 一律 404 `not_found_error`，不会进入转发。
    static func registerRoutes(
        on router: Router<BasicRequestContext>,
        configStore: ConfigStore,
        httpClient: HTTPClient
    ) {
        router.add(middleware: PathWhitelistMiddleware())
        router.post("v1/messages") { request, _ in
            try await Self.proxy(request, store: configStore, using: httpClient)
        }
        router.post("v1/messages/count_tokens") { request, _ in
            try await Self.countTokens(request, store: configStore, using: httpClient)
        }
        router.get("v1/models") { _, _ in
            try await Self.modelsList(store: configStore)
        }
    }

    /// 把客户端请求转发给命中 Provider 的上游：入口取当下快照并全程使用（design 5.1），
    /// 运行中换快照对新请求立即生效、在途请求持有旧快照自然完成。
    static func proxy(_ request: Request, store: ConfigStore, using httpClient: HTTPClient) async throws -> Response {
        let snapshot = await store.current()
        var request = request
        let body = try await request.collectBody(upTo: 64 * 1024 * 1024)

        // 模型归属路由（CONTEXT.md）：按请求 `model` 精确匹配启用的 Provider。
        let model = Self.requestedModel(in: body)
        guard let model,
            let provider = ModelRouter(providers: snapshot.providers).provider(forModel: model)
        else {
            return try Self.modelNotFound(model: model)
        }

        var upstream = HTTPClientRequest(url: Self.upstreamURL(baseUrl: provider.baseUrl, path: "/v1/messages"))
        upstream.method = .POST
        upstream.headers = forwardedHeaders(from: request.headers, apiKey: provider.apiKey)
        upstream.body = .bytes(body)
        let response: HTTPClientResponse
        do {
            response = try await httpClient.execute(upstream, deadline: .distantFuture)
        } catch {
            // 网关自身连不上上游（首字节前）→ Anthropic 502 api_error（spec 用户故事 12）；
            // 不重试、不转移。
            return try Self.apiError(
                message: "网关无法连接 Provider「\(provider.name)」的上游（\(provider.baseUrl)）"
            )
        }

        let fields = Self.filteredResponseFields(from: response.headers)

        // 首字节边界（design 5.2）：Hummingbird 在 handler 返回 Response 的瞬间
        // 就把响应头写给客户端，之后再无法改写状态码。因此先读到上游响应体的
        // 第一段再提交响应——上游若在首字节前失败（连接失败、停滞超时、回了
        // 响应头就断开），此刻还能完整转写 502；一旦开始写出就只能断开连接。
        var upstreamIterator = response.body.makeAsyncIterator()
        let firstChunk: ByteBuffer?
        do {
            firstChunk = try await upstreamIterator.next()
        } catch {
            return try Self.apiError(
                message: "Provider「\(provider.name)」的上游在响应首字节前中断（\(provider.baseUrl)）"
            )
        }
        guard let firstChunk else {
            // 上游响应体为空：原样回空体。
            return Response(status: HTTPResponse.Status(code: Int(response.status.code)), headers: fields)
        }

        // 上游响应体剩余分段逐段接进 Hummingbird 流式响应（contentLength 为
        // nil 走 chunked，design 5.2）：不聚合、不改写、不掐断。
        return Response(
            status: HTTPResponse.Status(code: Int(response.status.code)),
            headers: fields,
            body: .init(asyncSequence: FirstChunkThenUpstreamBody(
                first: firstChunk,
                rest: .init(iterator: upstreamIterator)
            ))
        )
    }

    // MARK: - 错误响应（Anthropic error 格式，design「3.1 通用约定」）

    /// 未命中：404 `model_not_found`（spec 用户故事 4）。
    static func modelNotFound(model: String?) throws -> Response {
        try errorResponse(
            status: .notFound,
            type: "model_not_found",
            message: "model: \(model ?? "<missing>") 未被任何启用的 Provider 声明"
        )
    }

    /// 未识别路径：404 `not_found_error`（spec 用户故事 23）。
    static func notFound() throws -> Response {
        try errorResponse(
            status: .notFound,
            type: "not_found_error",
            message: "未识别的路径或方法：网关仅支持 POST /v1/messages、POST /v1/messages/count_tokens、GET /v1/models"
        )
    }

    /// 网关连不上上游：502 `api_error`（spec 用户故事 12）。
    static func apiError(message: String) throws -> Response {
        try errorResponse(status: .badGateway, type: "api_error", message: message)
    }

    /// 统一构造 `{"type":"error","error":{"type":..,"message":..}}` 错误体。
    static func errorResponse(status: HTTPResponse.Status, type: String, message: String) throws -> Response {
        let payload: [String: Any] = [
            "type": "error",
            "error": ["type": type, "message": message],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var fields = HTTPFields()
        fields.append(HTTPField(name: .contentType, value: "application/json"))
        return Response(status: status, headers: fields, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    // MARK: - 转发细节

    /// 从缓冲后的请求体里读出路由依据 `model`（不改写请求体，仅用于查快照）。
    static func requestedModel(in body: ByteBuffer) -> String? {
        var body = body
        guard let data = body.readData(length: body.readableBytes),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["model"] as? String
    }

    /// 转发请求头：原样透传，仅鉴权头（`x-api-key` / `authorization`）替换为
    /// 命中 Provider 的 apiKey（客户端自己的 key 不外泄），并剔除逐跳头与
    /// 由 HTTP 客户端自行管理的头。同名多值头（如两条 `anthropic-beta`）
    /// 用追加语义逐条保留——`replaceOrAdd` 会只剩最后一个值。
    static func forwardedHeaders(from headers: HTTPFields, apiKey: String) -> HTTPHeaders {
        var forwarded = HTTPHeaders()
        for field in headers {
            let name = field.name.description
            let lowered = name.lowercased()
            guard !Self.hopByHopNames.contains(lowered), lowered != "x-api-key", lowered != "authorization" else { continue }
            forwarded.add(name: name, value: field.value)
        }
        forwarded.replaceOrAdd(name: "x-api-key", value: apiKey)
        return forwarded
    }

    /// 拼接上游 URL：baseUrl 规范化去尾斜杠（可带多个）后再拼子路径，
    /// 带尾斜杠的 baseUrl 不会拼出 `//v1/messages` 之类的双斜杠路径。
    /// messages 与 count_tokens 两条管线共用。
    static func upstreamURL(baseUrl: String, path: String) -> String {
        var base = baseUrl
        while base.hasSuffix("/") { base.removeLast() }
        return base + path
    }

    /// 响应方向的头过滤：剔除逐跳头后复制进 `HTTPFields`，messages 与
    /// count_tokens 两条管线共用。
    static func filteredResponseFields(from upstreamHeaders: HTTPHeaders) -> HTTPFields {
        var fields = HTTPFields()
        for (name, value) in upstreamHeaders {
            guard let name = HTTPField.Name(name) else { continue }
            let lowered = name.description.lowercased()
            guard !Self.responseHopByHopNames.contains(lowered) else { continue }
            fields.append(.init(name: name, value: value))
        }
        return fields
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

    /// 响应方向的逐跳头（RFC 9110 §7.6.1）：描述的是上游↔网关这一跳的连接语义，
    /// 透传给客户端会错误影响网关↔客户端连接（如上游的 `connection: close` 会
    /// 提前掐断客户端连接）。content-length 属于实体描述、长度与透传体一致，保留。
    private static let responseHopByHopNames: Set<String> = [
        "connection",
        "keep-alive",
        "proxy-connection",
        "proxy-authenticate",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ]
}

/// 首字节边界（design 5.2）用的拼接序列：把 `GatewayRouter.proxy` 预读出的
/// 上游首段与尚未消费的上游迭代器拼成一条流，整体接进 Hummingbird 的
/// `ResponseBody(asyncSequence:)` chunked 写出。
private struct FirstChunkThenUpstreamBody: AsyncSequence, Sendable {
    typealias Element = ByteBuffer

    private let first: ByteBuffer
    private let rest: UpstreamIteratorBox

    init(first: ByteBuffer, rest: UpstreamIteratorBox) {
        self.first = first
        self.rest = rest
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        private var first: ByteBuffer?
        private let rest: UpstreamIteratorBox

        init(first: ByteBuffer?, rest: UpstreamIteratorBox) {
            self.first = first
            self.rest = rest
        }

        mutating func next() async throws -> ByteBuffer? {
            if let chunk = self.first {
                self.first = nil
                return chunk
            }
            return try await self.rest.iterator?.next()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(first: self.first, rest: self.rest)
    }
}

/// `HTTPClientResponse.Body.AsyncIterator` 被 AsyncHTTPClient 刻意标为非
/// Sendable（迭代器持流内可变状态）。网关的用法是严格单次的：proxy 预读
/// 首段后，迭代器只在 Hummingbird 响应写出闭包里被单任务顺序消费、独占
/// 使用、从不并发共享，因此用 unchecked 装箱安全地穿过 Sendable 边界。
private final class UpstreamIteratorBox: @unchecked Sendable {
    var iterator: HTTPClientResponse.Body.AsyncIterator?

    init(iterator: HTTPClientResponse.Body.AsyncIterator) {
        self.iterator = iterator
    }
}

/// 白名单守卫（design「3.1」代理路径生命周期第一步）：
/// 方法 + 路径（查询参数一律忽略）不在网关白名单内的请求直接 404 `not_found_error`
/// （spec 用户故事 23），不进转发。网关自己因此永远不会返回非 Anthropic 形态的 404；
/// 上游透传的 404 是白名单内路径的正常代理响应，不受影响。
/// 加在所有路由之前；白名单与下方注册的路由一一对应，后续任务同步扩展。
struct PathWhitelistMiddleware: MiddlewareProtocol {
    typealias Input = Request
    typealias Output = Response
    typealias Context = BasicRequestContext

    /// 网关白名单："METHOD /path"。
    static let whitelisted: Set<String> = [
        "POST /v1/messages",
        "POST /v1/messages/count_tokens",
        "GET /v1/models",
    ]

    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        guard Self.whitelisted.contains("\(request.method.rawValue) \(request.uri.path)") else {
            return try GatewayRouter.notFound()
        }
        return try await next(request, context)
    }
}
