# 04: SSE 流式转发

**做什么：** `stream: true` 的 `/v1/messages` 响应从上游逐段透传到客户端，不缓冲、不改写、不掐断——长流式会话体验与直连上游一致。

**阻塞于：** 03（messages 路由与错误路径已就绪）。

**状态：** 完成

## 上下文

- **相关用户故事**：spec 7（SSE 逐段转发不中断不缓冲篡改）。
- **设计决策**（自 design「5.2」摘录）：
  - 请求体整体读入内存后经 AsyncHTTPClient 转发（本地单用户，Anthropic 请求体上限 32MB 量级）；响应方向才流式。
  - 上游响应体 `AsyncSequence<ByteBuffer>` 逐段接进 Hummingbird 的响应流式 API（`ResponseBody(asyncSequence:)`，contentLength 为 nil 走 chunked）——与官方 proxy-server 示例同构。不得把流聚合成 Data 再回。
  - **首字节边界**：上游在响应首字节前失败 → 网关完整转写错误（502 `api_error`）；首字节已写出后失败 → 无法改写已开始的流，直接关闭连接。
  - **超时**（design 2.3）：connect 10s；read 空闲 180s（AsyncHTTPClient 的 read 超时是空闲语义，覆盖长思考的首 token 分钟级延迟；正常 SSE 分段间隔远小于此值）；无资源总超时，避免掐断超长会话。不重试。
  - 响应头（`content-type: text/event-stream` 等）透传。
- **seam 约定**：复用 **HTTP 端到端 seam**；假上游需要能以受控节奏分段发送 SSE 事件（如首事件后延迟再发次事件），用于断言「客户端在 upstream 结束前已收到前段」。

## 验收标准

- [x] 端到端：`stream: true` 请求的 SSE 事件逐段、按序、完整到达客户端，`content-type` 透传
- [x] 端到端：**渐进到达**——假上游发送首事件后人为延迟，客户端在延迟期内已收到首事件（证明无整体缓冲）
- [x] 端到端：上游 SSE 首字节前连接失败 → 客户端收到 502 `api_error`，而不是半开的流
- [x] 端到端：流中途上游断开 → 客户端连接终止，网关不崩溃、后续请求不受影响
- [x] 超时配置生效且可验证（connect/read 空闲语义，read 期间有数据到达不掐断长流）
- [x] 非流式请求（`stream: false` 或缺省）行为不回归（任务 03 用例仍绿）
