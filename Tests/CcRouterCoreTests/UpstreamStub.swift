import AsyncHTTPClient
import Hummingbird
import HTTPTypes
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

/// 假上游「流中途断开」的信号：Response 头已写出后抛出，
/// Hummingbird 无法回收已开始的响应，只能断开连接。
struct UpstreamAbortError: Error {}

/// A request received by the fake upstream.
struct UpstreamRecordedRequest: Sendable {
    let method: String
    let uri: String
    let headers: [(name: String, value: String)]
    let body: ByteBuffer
}

/// The fixed response the fake upstream returns.
struct UpstreamResponse: Sendable {
    var status: HTTPResponse.Status = .ok
    var headers: [(name: String, value: String)] = [("content-type", "application/json")]
    var body: String = #"{"type":"message"}"#
    /// 记录请求后、返回响应前的人工延迟，用于构造「在途请求」。
    var delay: Duration? = nil
    /// 分段发送的响应体（设置后优先于 body）：每段附带发送前的人工延迟，
    /// 用于以受控节奏模拟 SSE 逐段输出（任务 04 seam 约定）。
    var chunks: [(data: String, delay: Duration?)]? = nil
    /// 发送完全部 chunks 后不断开正常收尾而是直接失败，模拟上游流中途挂掉。
    var abortAfterChunks: Bool = false
}

/// Fake Anthropic-compatible upstream: a real in-process HTTP server that
/// records every request it receives and answers with a fixed response.
final class UpstreamStub: @unchecked Sendable {
    private let response: UpstreamResponse
    private var runner: HttpServerRunner?

    private let recorded = NIOLockedValueBox<[UpstreamRecordedRequest]>([])
    private let waiters = NIOLockedValueBox<[CheckedContinuation<UpstreamRecordedRequest, Never>]>([])

    init(response: UpstreamResponse) {
        self.response = response
    }

    func start() async throws -> Int {
        guard self.runner == nil else { throw TestSupportError("upstream already started") }
        let router = Router(context: BasicRequestContext.self)
        let response = self.response
        router.post("v1/messages") { [weak self] request, _ -> Response in
            var request = request
            let body = try await request.collectBody(upTo: 64 * 1024 * 1024)
            let recordedRequest = UpstreamRecordedRequest(
                method: request.method.description,
                uri: request.uri.description,
                headers: request.headers.map { ($0.name.description, $0.value) },
                body: body
            )
            self?.record(recordedRequest)
            if let delay = response.delay {
                try await Task.sleep(for: delay)
            }
            var fields = HTTPFields()
            for (name, value) in response.headers {
                guard let name = HTTPField.Name(name) else { continue }
                fields.append(.init(name: name, value: value))
            }
            if let chunks = response.chunks {
                // 分段响应：逐段写出，段间遵守人为延迟；可选地在末尾直接失败
                // 模拟上游流中途断开（Response 头已写出后无法回收，连接随之断掉）。
                let abortAfterChunks = response.abortAfterChunks
                let body = ResponseBody(contentLength: nil) { writer in
                    for chunk in chunks {
                        if let delay = chunk.delay {
                            try await Task.sleep(for: delay)
                        }
                        try await writer.write(ByteBuffer(string: chunk.data))
                    }
                    if abortAfterChunks {
                        throw UpstreamAbortError()
                    }
                    try await writer.finish(nil)
                }
                return Response(status: response.status, headers: fields, body: body)
            }
            return Response(status: response.status, headers: fields, body: .init(byteBuffer: ByteBuffer(string: response.body)))
        }
        let runner = HttpServerRunner(router: router, address: "127.0.0.1", port: 0)
        self.runner = runner
        return try await runner.start()
    }

    func stop() async throws {
        guard let runner = self.runner else { return }
        self.runner = nil
        try await runner.stop()
    }

    /// The last recorded request; waits until one arrives.
    func lastRequest() async -> UpstreamRecordedRequest {
        await withCheckedContinuation { continuation in
            let ready: UpstreamRecordedRequest? = self.recorded.withLockedValue { recorded in
                if let last = recorded.last {
                    return last
                }
                self.waiters.withLockedValue { $0.append(continuation) }
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }

    /// Number of requests recorded so far (no waiting involved).
    func requestCount() -> Int {
        self.recorded.withLockedValue { $0.count }
    }

    private func record(_ request: UpstreamRecordedRequest) {
        let ready: [CheckedContinuation<UpstreamRecordedRequest, Never>] = self.recorded.withLockedValue { recorded in
            recorded.append(request)
            return self.waiters.withLockedValue { waiters in
                let released = waiters
                waiters.removeAll()
                return released
            }
        }
        for waiter in ready {
            waiter.resume(returning: request)
        }
    }
}
