import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import CcRouterCore

/// SSE 流式转发端到端（任务 04）：真 HTTP 客户端 → 网关 → 假上游，
/// 上游以受控节奏分段发送事件，断言响应方向逐段透传、不缓冲、不掐断。
@Suite("SSE 流式转发端到端")
struct SSEStreamingEndToEndTests {
    /// 三段典型 Anthropic SSE 事件（每段以空行收尾，构成合法 event 流）。
    private static let eventStart = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
    private static let eventDelta = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\"}\n\n"
    private static let eventStop = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

    private static let sseHeaders: [(name: String, value: String)] = [
        ("content-type", "text/event-stream"),
        ("x-request-id", "up-sse-01"),
    ]

    @Test("SSE 事件逐段、按序、完整到达客户端，content-type 等响应头透传")
    func streamsEventsInOrder() async throws {
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (
                UpstreamResponse(
                    headers: Self.sseHeaders,
                    chunks: [(Self.eventStart, nil), (Self.eventDelta, .milliseconds(150)), (Self.eventStop, nil)]
                ),
                ["sse-model"],
                true
            ),
        ])
        do {
            let response = try await fixture.streamMessages(model: "sse-model")
            #expect(response.status == .ok)
            #expect(firstValue(of: "content-type", in: response.headers) == "text/event-stream")
            #expect(firstValue(of: "x-request-id", in: response.headers) == "up-sse-01")
            // 流式响应不预告总长：客户端按 chunked 接收，没有 content-length。
            #expect(firstValue(of: "content-length", in: response.headers) == nil)

            var collected = ""
            for try await buffer in response.body {
                collected += String(buffer: buffer)
            }
            #expect(collected == Self.eventStart + Self.eventDelta + Self.eventStop)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("渐进到达：上游首事件后人为延迟，客户端在延迟期内已收到首事件（无整体缓冲）")
    func deliversFirstEventBeforeUpstreamFinishes() async throws {
        // 上游：首事件立发，次事件延迟 2 秒。若网关整体缓冲，客户端只能在
        // 上游收尾后（≥2s）才见到首字节。
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (
                UpstreamResponse(
                    headers: Self.sseHeaders,
                    chunks: [(Self.eventStart, nil), (Self.eventDelta, .seconds(2))]
                ),
                ["sse-model"],
                true
            ),
        ])
        do {
            let clock = ContinuousClock()
            let startedAt = clock.now

            let response = try await fixture.streamMessages(model: "sse-model")
            var iterator = response.body.makeAsyncIterator()
            guard let firstChunk = try await iterator.next() else {
                Issue.record("响应体没有任何分段")
                return
            }
            let firstChunkElapsed = clock.now - startedAt
            #expect(String(buffer: firstChunk).contains("message_start"))
            // 首事件在上游人为延迟期内到达（远早于上游整体结束的 2 秒）。
            #expect(firstChunkElapsed < .seconds(1))

            // 上游确实延迟了：整体消费完至少要等到 2 秒的延迟结束。
            while let chunk = try await iterator.next() {
                #expect(!String(buffer: chunk).isEmpty)
            }
            let finishedElapsed = clock.now - startedAt
            #expect(finishedElapsed >= .seconds(1))
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("响应方向的逐跳头（connection/keep-alive/transfer-encoding 等）不透传")
    func stripsHopByHopResponseHeaders() async throws {
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (
                UpstreamResponse(
                    headers: [
                        ("content-type", "text/event-stream"),
                        ("keep-alive", "timeout=99, max=99"),
                        ("upgrade", "websocket"),
                        ("x-request-id", "up-sse-01"),
                    ],
                    chunks: [(Self.eventStart, nil)]
                ),
                ["sse-model"],
                true
            ),
        ])
        do {
            let response = try await fixture.streamMessages(model: "sse-model")
            #expect(firstValue(of: "content-type", in: response.headers) == "text/event-stream")
            #expect(firstValue(of: "x-request-id", in: response.headers) == "up-sse-01")
            // 逐跳头描述的是上游↔网关这一跳，透传给客户端会错误影响
            // 网关↔客户端连接的语义，必须剔除。
            #expect(firstValue(of: "keep-alive", in: response.headers) == nil)
            #expect(firstValue(of: "upgrade", in: response.headers) == nil)
            var collected = ""
            for try await buffer in response.body {
                collected += String(buffer: buffer)
            }
            #expect(collected == Self.eventStart)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("流中途上游断开：客户端连接终止，网关不崩溃、后续请求不受影响")
    func midStreamUpstreamAbortTerminatesClientConnection() async throws {
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (
                UpstreamResponse(
                    headers: Self.sseHeaders,
                    chunks: [(Self.eventStart, .milliseconds(100)), (Self.eventDelta, .milliseconds(100))],
                    abortAfterChunks: true
                ),
                ["sse-model"],
                true
            ),
            // 中断后的健康对照上游：验证网关进程存活、连接池未被拖垮。
            (UpstreamResponse(body: #"{"id":"after-abort"}"#), ["model-after"], true),
        ])
        do {
            let response = try await fixture.streamMessages(model: "sse-model")
            #expect(response.status == .ok)
            var collected = ""
            var streamFailed = false
            do {
                for try await buffer in response.body {
                    collected += String(buffer: buffer)
                }
            } catch {
                // 中途断开必须以错误显式暴露给客户端，不能伪装成正常结束。
                streamFailed = true
            }
            #expect(streamFailed)
            // 中断前发出的分段已到达（若 RST 吞掉尾部缓冲，至少首事件在）。
            #expect(collected.contains("message_start"))
            #expect(!collected.contains("message_stop"))

            // 网关不崩溃：后续请求照常路由、照常代理。
            let followUp = try await fixture.postMessages(model: "model-after")
            #expect(followUp.status == .ok)
            #expect(followUp.body == #"{"id":"after-abort"}"#)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("上游回了响应头、但响应体首字节前断开 → 502 api_error，而不是半开的流")
    func upstreamDiesBeforeFirstBodyByteYields502() async throws {
        // 上游写出 200 + text/event-stream 响应头后，不发任何事件就断开。
        // 网关此刻尚未向客户端写出任何字节，必须能完整转写 502（design 5.2
        // 首字节边界），而不是让客户端拿着一个半开的 200 事件流。
        let fixture = try await RoutingFixture.start(providerSpecs: [
            (
                UpstreamResponse(headers: Self.sseHeaders, chunks: [], abortAfterChunks: true),
                ["sse-model"],
                true
            ),
            // 转写后的健康对照：验证网关进程存活。
            (UpstreamResponse(body: #"{"id":"after-half-open"}"#), ["model-after"], true),
        ])
        do {
            do {
                let response = try await fixture.postMessages(model: "sse-model")
                #expect(response.status == .badGateway)
                #expect(anthropicError(from: response.body)?.type == "api_error")
            } catch {
                Issue.record("首字节前失败应转写为 502 错误体，而不是把连接错误抛给客户端：\(error)")
            }

            // 网关不崩溃：后续请求照常。
            let followUp = try await fixture.postMessages(model: "model-after")
            #expect(followUp.status == .ok)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }
}

/// 上游超时语义端到端（任务 04）：向网关注入短超时配置验证「配置生效且语义正确」
/// ——read 是空闲超时（持续有数据的长流不掐断、停滞的流才掐）、首字节前超时转写
/// 502、connect 超时转写 502，以及生产默认值（connect 10s / read 空闲 180s）。
@Suite("上游超时端到端")
struct UpstreamTimeoutEndToEndTests {
    private static let eventStart = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
    private static let sseHeaders: [(name: String, value: String)] = [
        ("content-type", "text/event-stream"),
    ]

    /// 注入网关的上游客户端配置（connect 保持生产值 10s，read 压到给定的短空闲值）。
    private static func fastReadConfig(_ readIdle: TimeAmount) -> HTTPClient.Configuration {
        HTTPClient.Configuration(
            timeout: .init(connect: GatewayServer.upstreamConnectTimeout, read: readIdle)
        )
    }

    @Test("read 是空闲超时：流中持续有数据到达，长于超时值的流不被掐断")
    func readIdleTimeoutDoesNotKillActiveStream() async throws {
        // 6 段事件、段间 0.15s，总时长约 0.9s —— 远超注入的 0.4s read 空闲超时；
        // 若语义是资源总超时，这条流必被掐断。
        let chunks = (0..<6).map { _ in (Self.eventStart, Duration.milliseconds(150)) }
        let fixture = try await RoutingFixture.start(
            providerSpecs: [
                (UpstreamResponse(headers: Self.sseHeaders, chunks: chunks), ["sse-model"], true)
            ],
            httpClientConfiguration: Self.fastReadConfig(.milliseconds(400))
        )
        do {
            let response = try await fixture.streamMessages(model: "sse-model", timeout: .seconds(30))
            var collected = ""
            for try await buffer in response.body {
                collected += String(buffer: buffer)
            }
            #expect(collected == String(repeating: Self.eventStart, count: 6))
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("流中途上游停滞超过 read 空闲超时：客户端连接被掐断，网关不崩溃")
    func readIdleTimeoutStopsStalledStream() async throws {
        // 上游发出首事件后停滞 3s（超过注入的 0.5s read 空闲超时）。
        let fixture = try await RoutingFixture.start(
            providerSpecs: [
                (
                    UpstreamResponse(
                        headers: Self.sseHeaders,
                        chunks: [(Self.eventStart, nil), (Self.eventStart, .seconds(3))]
                    ),
                    ["sse-model"],
                    true
                ),
                // 掐断后的健康对照：验证网关存活。
                (UpstreamResponse(body: #"{"id":"after-stall"}"#), ["model-after"], true),
            ],
            httpClientConfiguration: Self.fastReadConfig(.milliseconds(500))
        )
        do {
            let response = try await fixture.streamMessages(model: "sse-model", timeout: .seconds(30))
            var collected = ""
            var streamFailed = false
            do {
                for try await buffer in response.body {
                    collected += String(buffer: buffer)
                }
            } catch {
                streamFailed = true
            }
            #expect(streamFailed)
            #expect(collected.contains("message_start"))

            // 网关不崩溃：后续请求照常。
            let followUp = try await fixture.postMessages(model: "model-after")
            #expect(followUp.status == .ok)
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("上游迟迟不回响应头（首字节前停滞）→ read 超时转写 502 api_error")
    func stalledBeforeHeadYields502() async throws {
        // 上游收到请求后睡 2s 才开始响应；注入 read 0.5s → 网关在首字节前
        // 放弃并转写 Anthropic 502（spec 用户故事 12，design 5.2 首字节边界）。
        let fixture = try await RoutingFixture.start(
            providerSpecs: [
                (UpstreamResponse(delay: .seconds(2)), ["sse-model"], true)
            ],
            httpClientConfiguration: Self.fastReadConfig(.milliseconds(500))
        )
        do {
            let response = try await fixture.postMessages(model: "sse-model")
            #expect(response.status == .badGateway)
            #expect(anthropicError(from: response.body)?.type == "api_error")
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("connect 超时（不可达且无响应的地址）→ 502 api_error，且不用等满 read 超时")
    func connectTimeoutYields502Promptly() async throws {
        // 192.0.2.1 是 RFC 5737 TEST-NET-1，保证不可路由：连接请求只能
        // 挂到超时。注入 connect 0.5s（生产 10s）验证它在超时后立刻转写 502。
        let provider = Provider(
            name: "挂死上游",
            baseUrl: "http://192.0.2.1:81",
            apiKey: "upstream-key-hang",
            models: ["model-connect-hang"],
            enabled: true
        )
        let fixture = try await RoutingFixture.start(
            providers: [provider],
            httpClientConfiguration: HTTPClient.Configuration(
                timeout: .init(connect: .milliseconds(500), read: .seconds(180))
            )
        )
        do {
            let clock = ContinuousClock()
            let startedAt = clock.now
            let response = try await fixture.postMessages(model: "model-connect-hang")
            let elapsed = clock.now - startedAt
            #expect(response.status == .badGateway)
            #expect(anthropicError(from: response.body)?.type == "api_error")
            #expect(elapsed < .seconds(3))
        } catch {
            try? await fixture.shutdown()
            throw error
        }
        try await fixture.shutdown()
    }

    @Test("生产默认超时配置：connect 10s / read 空闲 180s（design 2.3）")
    func defaultUpstreamTimeoutsMatchSpec() {
        #expect(GatewayServer.upstreamConnectTimeout == .seconds(10))
        #expect(GatewayServer.upstreamReadIdleTimeout == .seconds(180))
        let configuration = GatewayServer.defaultUpstreamHTTPClientConfiguration()
        #expect(configuration.timeout.connect == .seconds(10))
        #expect(configuration.timeout.read == .seconds(180))
    }
}
