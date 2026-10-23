# cc-router-mac

Anthropic 格式 API 网关（macOS 菜单栏应用）的领域术语表。

## Language

**Provider**:
一个上游 Anthropic 兼容端点的完整配置：名称、base_url、api_key、模型列表、启用开关、在列表中的顺序。
_Avoid_: 上游、渠道、channel

**模型归属路由**:
按请求体中的 `model` 字段精确匹配各启用 provider 的模型列表来选择 provider 的路由方式。同一模型不允许被多个 provider 声明（配置保存时全局校验，与启用状态无关）；无匹配时返回 404。不包含故障转移，无兜底 provider。
_Avoid_: failover、负载均衡、轮询、通配匹配

**主开关**:
控制网关 HTTP 服务整体启停的开关；各 provider 另有独立的启用开关。
_Avoid_: 服务开关、电源
