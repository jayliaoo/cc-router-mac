# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目目标

**cc-router-mac**：一个 macOS 原生应用（SwiftUI），作为 **Anthropic Messages API 格式的网关**，供 Claude Code 等客户端把 `ANTHROPIC_BASE_URL` 指向本网关使用。

核心需求（来自项目发起人，尚未实现）：

- **只做聚合，不做协议转换**：所有上游 provider 本身就是 Anthropic 兼容格式（如 Anthropic 官方、第三方 Anthropic 兼容端点）。网关不改写请求/响应体、不改写 `model` 名，只替换鉴权头（`x-api-key`/`authorization`）为命中 provider 的 key，其余 headers 原样透传。
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
- **App 壳构建（Xcode 工程，菜单栏 app）**：
  - 重新生成工程（改 `project.yml` 后）：`xcodegen generate`（需 [xcodegen](https://github.com/yonaskolb/XcodeGen)，`brew install xcodegen`；生成的 `cc-router-mac.xcodeproj/project.pbxproj` 入库）
  - 构建：`xcodebuild -project cc-router-mac.xcodeproj -scheme cc-router-mac -configuration Debug build CODE_SIGNING_ALLOWED=NO`
  - 运行/手测：Xcode GUI 打开 `cc-router-mac.xcodeproj` 直接 Run（本机签名自动处理）；UI 无自动化测试，按任务文件手测
- **依赖**：Hummingbird 2.x（server）、AsyncHTTPClient（上游 client）、SwiftNIO（`Package.resolved` 已锁定）；App 壳经本地包引用产品 `CcRouterCore`，壳内只有 UI 与生命周期编排
- **最低平台**：macOS 14 —— Hummingbird 2.28 的 API 经其 availability macro 要求 macOS 14（spec 曾定 macOS 13，见 ADR-0001 与 Package.swift 注释）
- App 壳（SwiftUI `MenuBarExtra`，`LSUIElement` 不进 Dock）位于 `App/`，入口 `App/CcRouterApp.swift`；provider 编辑设置窗口尚未实现（任务 07）。

## 注意事项

- 根目录有一个未纳入版本控制的 `.github_token` 文件（含敏感凭据）。**永远不要提交它**，也不要在代码、日志、文档中引用其内容。
