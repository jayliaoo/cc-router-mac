# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目目标

**cc-router-mac**：一个 macOS 原生应用（SwiftUI），作为 **Anthropic Messages API 格式的网关**，供 Claude Code 等客户端把 `ANTHROPIC_BASE_URL` 指向本网关使用。

核心需求（来自项目发起人）：

- **只做聚合，不做协议转换**：所有上游 provider 本身是 Anthropic 兼容格式的第三方端点（注意：Anthropic 官方 API 不接受 Bearer 鉴权）。网关不改写请求/响应体、不改写 `model` 名，只替换鉴权头为命中 provider 的 key——**统一以 `Authorization: Bearer <key>` 发给上游**（ANTHROPIC_AUTH_TOKEN 兼容模式，客户端原有的 `x-api-key`/`authorization` 剔除），其余 headers 原样透传。
- **多个 provider 聚合成一个端点**：provider = { 名称, base_url, api_key, 模型列表, 启用开关, 顺序 }，单 provider 单 key。路由采用**模型归属路由**（术语见 CONTEXT.md）：按请求 `model` 精确匹配；同一模型不允许被多个 provider 声明（保存配置时全局校验拒绝，不看启用状态）；模型列表不允许留空；未命中返回 Anthropic 格式 404 `model_not_found`。
- **不做故障转移**：上游 HTTP 错误原样透传；网关自身连不上上游转写为 Anthropic 格式 502 `api_error`；不重试不转移。
- **网关不校验客户端凭据**：任意 key 放行。
- **接口范围**（须容忍 `?beta=true`、`?limit=1000` 等查询参数变体）：
  - `POST /v1/messages`：核心对话接口，支持流式（SSE）与非流式响应
  - `POST /v1/messages/count_tokens`：透传；上游失败时网关直接返回 `{"input_tokens": 0}`
  - `GET /v1/models`：返回启用的 provider 所声明模型列表的聚合
  - `GET /v1/models/{model_id}` 不做；其余未识别路径 404
- **Switch UI**：菜单栏 app（静态图标）+ popover：网关主开关（启停）+ 各 provider 启用开关；「设置…」打开配置窗口（provider 列表可排序、表单编辑、api_key 掩码、重复/空模型列表校验标红）。
- **运行行为**：配置持久化；App 启动恢复上次主开关状态；设置内提供「登录时启动」开关；运行中改动热生效、在途请求不受影响。
- **监听**：默认 `127.0.0.1:8317`，地址/端口可在设置修改，保存后重启监听，占用时明确报错。
## 仓库现状

已有核心 SPM 包（仓库根 `Package.swift`，产品名 `CcRouterCore`）与菜单栏 App 壳（Xcode 工程），无 lint 配置：

- **核心包构建**：`swift build`
- **核心包测试**：`swift test`（全部自动化测试位于核心包内，HTTP 端到端 seam：进程内假 Anthropic 上游 + 网关 + 真 HTTP 客户端）
- **跑单个测试**：`swift test --filter <Suite 或完整用例名>`，如 `swift test --filter ConfigValidationTests`、`swift test --filter 'CcRouterCoreTests.SSEStreamingEndToEndTests'`
- **App 壳构建（Xcode 工程，菜单栏 app）**：
  - 重新生成工程（改 `project.yml` 后）：`xcodegen generate`（需 [xcodegen](https://github.com/yonaskolb/XcodeGen)，`brew install xcodegen`；生成的 `cc-router-mac.xcodeproj/project.pbxproj` 入库）
  - 构建：`xcodebuild -project cc-router-mac.xcodeproj -scheme cc-router-mac -configuration Debug build CODE_SIGNING_ALLOWED=NO`
  - 运行/手测：Xcode GUI 打开 `cc-router-mac.xcodeproj` 直接 Run（本机签名自动处理）；UI 无自动化测试，按任务文件手测
- **依赖**：Hummingbird 2.x（server）、AsyncHTTPClient（上游 client）、SwiftNIO（`Package.resolved` 已锁定）；App 壳经本地包引用产品 `CcRouterCore`，壳内只有 UI 与生命周期编排
- **最低平台**：macOS 14 —— Hummingbird 2.28 的 API 经其 availability macro 要求 macOS 14（spec 曾定 macOS 13，见 ADR-0001 与 Package.swift 注释）
- App 壳（SwiftUI `MenuBarExtra`，`LSUIElement` 不进 Dock）位于 `App/`，入口 `App/CcRouterApp.swift`；provider 编辑设置窗口已实现（`App/SettingsWindow.swift`：provider 列表排序、表单编辑、api_key 掩码、校验标红、监听地址端口修改）。

## 架构总览

请求通路：客户端 → 进程内 Hummingbird（`GatewayServer`，ADR-0002）→ `PathWhitelistMiddleware`（白名单外直接 404 `not_found_error`，查询参数忽略）→ 取 `ConfigStore` 当下快照 → `ModelRouter` 按 `model` 精确匹配**启用**的 provider → AsyncHTTPClient 转发（仅换鉴权头）→ 流式回写。App 壳（`AppModel`）不做网关逻辑，只把 popover 开关翻译为 `ConfigStore.save` + `GatewayServer.start/stop`。

跨多文件才能看出的关键设计约定：

- **快照热生效是全局模式**：配置唯一真相源是 `ConfigStore`（actor），持有不可变 `ConfigSnapshot`；修改一律经 `save()`（校验 → 原子落盘 `0600` → 换内存快照）。每个请求入口取一次快照并全程使用，运行中改配置对新请求立即生效、在途请求持旧快照自然完成。改配置相关代码时不要引入旁路状态。
- **首字节边界**（`GatewayRouter.proxy`）：Hummingbird 在 handler 返回 Response 瞬间就写出响应头，之后无法改状态码；因此先读上游响应体首段再提交响应——首字节前上游失败可转写 502 `api_error`，之后逐段流式接出、不聚合。`/v1/messages/count_tokens` 是另一条管线：整体读入（1MB 上限），任何上游失败/非 2xx 一律兜底 `200 {"input_tokens":0}`。
- **上游 HTTP 客户端必须跑 NIO 而非 NIOTS**：macOS 的 AsyncHTTPClient 默认 NW 路径不遵守 connect timeout（实测 ~15.5s TCP 重试上限）；`GatewayServer` 用 `.shared(MultiThreadedEventLoopGroup.singleton)` 才能实现 design 2.3 的 connect 10s / read 空闲 180s 超时语义。
- **请求/响应方向头处理不对称**（`GatewayRouter`）：请求方向剔逐跳头 + `host`/`content-length`、鉴权头替换为命中 provider 的 apiKey、**多值头用 `add` 逐条保留**（`replaceOrAdd` 会丢值）；响应方向剔逐跳头但保留 `content-length`。
- **AHC body 迭代器刻意非 Sendable**：`UpstreamIteratorBox` 用 `@unchecked` 装箱穿过 Sendable 边界，前提是严格单任务顺序消费——`PortPromise` 同理（等端口就绪）；测试侧 `TestSupport.swift` 有同构镜像。
- **测试 seam**（`Tests/CcRouterCoreTests/`）：`UpstreamStub` 进程内假 Anthropic 上游 + `HttpServerRunner` 起 `GatewayServer`（端口 0 由系统分配），真 HTTPClient 走真 HTTP 做端到端验证；配置校验/持久化是纯单元测试。新端点的端到端测试应沿用这一 seam，不引 HummingbirdTesting。

## 文档与出处

核心包与 App 壳的注释大量以「spec 用户故事 N」「design「N」」指代需求/设计条目，出处文件（含历史决策背景，修改行为前值得对照）：

- `.scratch/api-gateway/spec.md`：需求 spec（用户故事编号）
- `.scratch/api-gateway/design.md`：技术设计（章节号 N.M）
- `.scratch/api-gateway/tasks/01–07`：任务分解与验收标准（已全部完成）
- `docs/adr/`：架构决策记录（0001 Swift HTTP 栈选型、0002 进程内网关）
- `CONTEXT.md`：领域术语表（Provider、模型归属路由、主开关等，用词须与其一致）

## 注意事项

- 根目录有一个未纳入版本控制的 `.github_token` 文件（含敏感凭据）。**永远不要提交它**，也不要在代码、日志、文档中引用其内容。
