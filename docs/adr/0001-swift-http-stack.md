# HTTP 技术栈：Hummingbird 2.x + AsyncHTTPClient

macOS 菜单栏 app 内嵌的本地网关需要极少样板与可靠的双向流式（SSE 透传）。选定 Hummingbird 2.x 作 server（请求/响应体原生 `AsyncSequence<ByteBuffer>`，官方 proxy-server 示例与本项目需求几乎逐行对应），AsyncHTTPClient 作上游客户端（`response.body` 与 server 侧流式 API 一一对应，共享 SwiftNIO 生态，connect/read 超时语义显式且 read 为空闲超时，适合长 SSE）。否决项：Vapor（19 个直接依赖、按服务器应用设计，对本项目严重过剩，且 Vapor 5 抬到 macOS 26.2）；裸 SwiftNIO / Network.framework（重造 HummingbirdCore）；URLSession.bytes（可行但需 byte→buffer 转换胶水，首字节超时需手工保护）。

依据：2026-10 选型调研（Hummingbird 2.28 要求 Swift 6.2 工具链，本机 Xcode 27.1 / Swift 6.4 满足）。
