import AsyncHTTPClient
import Hummingbird
import HTTPTypes
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

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
            var fields = HTTPFields()
            for (name, value) in response.headers {
                guard let name = HTTPField.Name(name) else { continue }
                fields.append(.init(name: name, value: value))
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
