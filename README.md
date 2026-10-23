# cc-router-mac

macOS 菜单栏应用，作为 **Anthropic Messages API 格式的聚合网关**：把多个 Anthropic 兼容的上游 provider（官方、第三方兼容端点）聚合成一个本地端点，供 Claude Code 等客户端把 `ANTHROPIC_BASE_URL` 指向它使用。

只做聚合，不做协议转换：网关不改写请求/响应体、不改写 `model` 名，只按命中结果替换鉴权头为对应 provider 的 key——统一以 `Authorization: Bearer <key>` 发给上游（ANTHROPIC_AUTH_TOKEN 兼容模式），其余 headers 原样透传。

## 特性

- **模型归属路由**：按请求体中的 `model` 精确匹配各 provider 声明的模型列表；同一模型至多被一个 provider 声明（保存配置时全局校验，与启用状态无关）；未命中返回 Anthropic 格式 404 `model_not_found`
- **不做故障转移**：上游 HTTP 错误原样透传；网关连不上上游转写为 Anthropic 格式 502 `api_error`；不重试不转移
- **SSE 流式**完整透传（`/v1/messages`），首字节前上游中断仍能给出明确 502
- **菜单栏 Switch UI**：主开关（启停）+ 各 provider 独立开关 + 设置窗口（provider 排序/编辑、api_key 掩码、校验标红、监听地址端口修改、登录时启动）
- **热生效**：运行中改配置对新请求立即生效，在途请求不受影响
- 网关不校验客户端凭据，任意 key 放行

## 使用

1. 构建并运行（见下），菜单栏出现图标
2. 点菜单栏图标 →「设置…」配置 provider（界面见下）
3. 打开主开关，网关默认监听 `http://127.0.0.1:8317`
4. 客户端指向网关，例如：

```sh
export ANTHROPIC_BASE_URL=http://127.0.0.1:8317
```

### 配置界面

**菜单栏 popover**：

- 「网关」主开关（启停整个网关），下方显示当前监听地址与端口
- 各 provider 一行一个的启用开关；尚未配置任何 provider 时给出占位提示
- 「设置…」打开配置窗口，「退出」退出 App

**设置窗口**（左侧 provider 列表 + 右侧编辑表单）：

- **Provider 列表**：`+` 新增；选中项可「上移」/「下移」调整顺序、「删除」移除
- **编辑表单**：名称、baseUrl、apiKey（掩码显示，不因打开设置窗口泄露明文）、模型列表（一行一个，精确匹配、无通配）
- **校验标红**：保存被拒时列出全部原因并定位到对应 provider 的对应字段（模型列表留空、同一模型被多个 provider 声明、非法 baseUrl、空 apiKey）；校验与启用状态无关
- **监听**：地址与端口可改，保存后用新配置重启监听；端口被占用时明确报错并将主开关回落为关
- **登录时启动**：经系统「登录项」注册，登录即自动启动并恢复上次主开关状态
- 「保存」立即落盘并热生效（在途请求不受影响）；「还原未保存的修改」放弃草稿

### 支持的接口

| 端点 | 行为 |
| --- | --- |
| `POST /v1/messages` | 转发命中 provider，流式/非流式均支持 |
| `POST /v1/messages/count_tokens` | 同路由透传；上游失败兜底 `200 {"input_tokens":0}` |
| `GET /v1/models` | 本地聚合：启用 provider 所声明模型的并集 |

其余未识别路径/方法返回 Anthropic 格式 404 `not_found_error`；`GET /v1/models/{model_id}` 不支持。查询参数（`?beta=true` 等）被容忍并忽略。

配置持久化于 `~/Library/Application Support/cc-router-mac/config.json`（权限 `0600`），App 启动恢复上次主开关状态。

## 构建与运行

环境要求：macOS 14+、Xcode 15+（含 Swift 工具链）。

- **App**：用 Xcode 打开 `cc-router-mac.xcodeproj` 直接 Run（本机签名自动处理）
- **改过 `project.yml` 后重新生成工程**：`xcodegen generate`（[XcodeGen](https://github.com/yonaskolb/XcodeGen)，`brew install xcodegen`）
- **命令行构建 App（Debug）**：

```sh
xcodebuild -project cc-router-mac.xcodeproj -scheme cc-router-mac \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

- **生产构建（Release，本机可运行）**：

```sh
xcodebuild -project cc-router-mac.xcodeproj -scheme cc-router-mac \
  -configuration Release -derivedDataPath build build
open build/Build/Products/Release/cc-router-mac.app
```

产物为本机签名，仅本机可运行；分发需自行改用正式开发者签名与公证。

## 开发

仓库结构：核心 SPM 包（产品 `CcRouterCore`：网关 server、路由、配置存储）+ `App/` 菜单栏壳（仅 UI 与生命周期编排）。

```sh
swift build                 # 核心包
swift test                  # 全部自动化测试（含进程内假上游的 HTTP 端到端测试）
swift test --filter ConfigValidationTests   # 单个 Suite
```

架构决策见 `docs/adr/`，领域术语见 `CONTEXT.md`。

## License

[Apache-2.0](LICENSE)
