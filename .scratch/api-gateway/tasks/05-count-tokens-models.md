# 05: count_tokens 转发 + `/v1/models` 聚合

**做什么：** 两个次要端点达到最终行为：token 计数透传且永不阻塞客户端（失败兜底），模型列表接口返回启用 Provider 的聚合能力。完成后网关的接口面（messages / count_tokens / models）全部就位。

**阻塞于：** 03（路由与转发管线已就绪）。

**状态：** 完成

## 上下文

- **相关用户故事**：spec 8（count_tokens 透传、失败兜底 `{"input_tokens": 0}`）、9（models 聚合）、10（查询参数变体容忍）。
- **设计决策**（自 design「3.3」摘录）：
  - **`POST /v1/messages/count_tokens`**（容忍 `?beta=true`）：与 messages 走同一路由（按 `model` 精确匹配启用的 Provider），请求/响应原样转发。上游返回 2xx → 原样透传；**连接失败或任何非 2xx** → 网关直接返回 `200` 与 `{"input_tokens": 0}`（兜底优先于透传，保证客户端 token 估算永不阻塞会话）。未命中模型仍按 03 的规则 404 `model_not_found`（兜底只针对上游失败，不掩盖路由错误）。
  - **`GET /v1/models`**（容忍 `?limit=1000`）：**本地生成，不打上游**——聚合所有启用 Provider 声明的模型名，按名升序：

    ```json
    {
      "data": [
        {
          "id": "claude-sonnet-5-5",
          "display_name": "claude-sonnet-5-5",
          "created_at": "2025-01-01T00:00:00Z",
          "type": "model"
        }
      ],
      "first_id": "claude-sonnet-5-5",
      "last_id": "claude-sonnet-5-5",
      "has_more": false
    }
    ```

    `display_name` = 模型名；`created_at` 为固定占位值 `2025-01-01T00:00:00Z`；`data` 为空时 `first_id`/`last_id` 为 `null`；`has_more` 恒 `false`。客户端（Claude Code）只消费 `id`。
  - 背景（访谈事实）：Claude Code 的核心路径白名单含 count_tokens（常规会话真实调用）；models 仅在网关模型发现模式下被调用且失败可优雅跳过——因此 count_tokens 兜底比 models 更关键。
- **seam 约定**：复用 **HTTP 端到端 seam**。

## 验收标准

- [x] 端到端：count_tokens 请求路由到正确上游、响应原样透传（含 `?beta=true` 变体）
- [x] 端到端：count_tokens 上游连接失败 → `200` + `{"input_tokens": 0}`
- [x] 端到端：count_tokens 上游返回 401/429/500（非 2xx）→ `200` + `{"input_tokens": 0}`
- [x] 端到端：count_tokens 未命中模型 → 404 `model_not_found`（兜底不吞路由错误）
- [x] 端到端：`GET /v1/models` 与 `GET /v1/models?limit=1000` 返回聚合列表——只含启用 Provider 的模型、按名升序、字段形态符合上方 JSON、禁用 Provider 的模型不出现
- [x] 端到端：全部 Provider 禁用 → `data: []`、`first_id`/`last_id` 为 `null`、`has_more: false`
