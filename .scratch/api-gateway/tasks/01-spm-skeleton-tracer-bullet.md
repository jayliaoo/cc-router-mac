# 01: SPM 包骨架 + 透传 tracer bullet

**做什么：** 核心逻辑包能构建、能测试；一条最小端到端链路打通——测试进程内起一个假 Anthropic 上游（临时端口），网关把 `POST /v1/messages`（非流式）原样转发给一个写死配置的上游并把响应原样送回真 HTTP 客户端。这同时立起项目全部自动化测试要用的 seam（进程内假上游 + HTTP 端到端）。

**阻塞于：** 无（可立即开始）。

**状态：** 进行中

## 上下文

- **相关用户故事**：spec 1（单一端点使用所有上游）、13（headers 原样透传、仅鉴权头替换）。
- **设计决策**：
  - 技术栈已定（ADR-0001）：server 用 **Hummingbird 2.x**（hummingbird-project，跟随最新 minor），上游 client 用 **AsyncHTTPClient**。否决项：Vapor、裸 SwiftNIO、Network.framework、URLSession.bytes——理由与调研记录见 `docs/adr/0001-swift-http-stack.md`。
  - 网关内嵌 app 进程（ADR-0002）；本任务只在测试里以进程内方式起 server（ServiceGroup 托管），不需要 GUI。
  - 核心包是仓库根的 SPM library（建议 target 名 `CcRouterCore`；若与既有代码冲突以既有代码为准），不依赖任何 UI 框架。本任务网关用一个写死的单 provider 配置（如 baseUrl 指向测试起的假上游），配置体系由任务 02 引入。
  - 转发契约（本任务实现最小子集）：客户端 headers 原样透传，仅 `x-api-key` / `authorization` 替换为上游 apiKey；请求体与响应体不改写；路径前缀 `/v1`；查询参数忽略（`?beta=true` 与无参数同路由）。
  - 官方参考：Hummingbird 示例库 `proxy-server`（hummingbird-examples）与本需求的转发形态几乎逐行对应，实现时可模仿。
- **约束**（spec）：macOS 原生 Swift + SwiftUI；最低 macOS 13；只聚合不转换。本机 Xcode 27.1 / Swift 6.4（Hummingbird 2.28 要求 Swift 6.2+ 工具链，已满足）。
- **seam 约定**（design「测试设计」）：
  - **HTTP 端到端**为最高层 seam：测试在进程内起假 Anthropic 上游（真 HTTP server、监听 `127.0.0.1` 临时端口）+ 网关（同样临时端口），用真 HTTP 客户端往返断言。此夹具一旦立起，后续任务（03/04/05）全部复用，不再新建 seam。
  - 所有测试放核心包内，`swift test` 直接运行，不依赖 Xcode。

## 验收标准

- [ ] `swift build` 与 `swift test` 在仓库根直接可用（核心包 + 测试 target）
- [ ] 端到端测试：客户端 → 网关 `POST /v1/messages` → 假上游，响应体、响应状态码、响应头原样到达客户端
- [ ] 端到端测试：客户端自带的 `x-api-key`/`authorization` 不出现在发往上游的请求里，上游收到的是配置的 apiKey
- [ ] 端到端测试：`POST /v1/messages?beta=true` 与无参数走同一处理
- [ ] 网关 server 可 start/stop（测试可重复起停），监听地址端口可指定
- [ ] 无 UI 代码、无 Hummingbird/AHC 之外的第三方依赖
