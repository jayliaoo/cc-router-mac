# 02: ConfigStore：配置模型、校验、快照、持久化

**做什么：** 网关的全部持久化状态（provider 列表、监听配置、主开关）成为可校验、可读写、可热交换的配置体系：JSON 文件读写 + 保存时校验拒绝非法配置 + 内存中不可变快照原子交换（任务 03/06 的路由与 UI 都建立在它上面）。

**阻塞于：** 01（包骨架与测试设施已就绪）。

**状态：** 进行中

## 上下文

- **相关用户故事**：spec 5（同模型多 provider 保存时拒绝并标红）、6（模型列表不允许留空）、15（provider 独立启用开关）、16（增删改排序）、18（配置跨启动持久化）。
- **设计决策**（自 design「数据设计」摘录）：
  - 单一 JSON 文件，位于 Application Support（具体文件名与目录构造自行探索决定），是全部持久化状态，无数据库。`schemaVersion` 预留演进。结构：

    ```json
    {
      "schemaVersion": 1,
      "gatewayEnabled": true,
      "listen": { "address": "127.0.0.1", "port": 8317 },
      "providers": [
        {
          "id": "uuid",
          "name": "官方",
          "baseUrl": "https://api.anthropic.com",
          "apiKey": "sk-...",
          "models": ["claude-sonnet-5-5"],
          "enabled": true
        }
      ]
    }
    ```

  - **保存时校验**（失败拒绝落盘，返回可展示的错误信息，UI 标红由任务 06/07 消费）：
    - `models`：每个 provider 至少一项；**跨 provider 全局唯一，校验与启用状态无关**。
    - `baseUrl` 非空合法 URL；`apiKey` 非空；`id` 唯一。
    - `providers` 数组顺序仅用于 UI 展示排序，路由不依赖顺序。
  - **持久化策略**：临时文件 + rename 原子替换（崩溃不产生半写文件）；文件权限 `0600`；**apiKey 明文存储**（已确认的决策：单用户本地场景依赖本机用户隔离与 FileVault，Keychain 收益不抵复杂度）。
  - **并发与热生效**（design「5.1」）：内存配置是不可变的 `ConfigSnapshot` 值类型；`ConfigStore`（actor）持有当前快照；任何修改构造新快照后原子替换；请求入口取当下快照并全程使用，读路径无锁。请求持有旧快照自然完成即「在途请求不受影响」的来源。
- **术语**：Provider / 主开关 的定义见根目录 CONTEXT.md。
- **seam 约定**：**纯逻辑单元** seam——校验规则、JSON round-trip、快照交换均为纯逻辑单元测试（`swift test`），不起 HTTP。持久化测试写临时目录，不碰真实 Application Support。

## 验收标准

- [ ] 单元测试：空 `models`、跨 provider 重复模型（含「重复项中有 provider 被禁用」的情形）、非法 URL、空 apiKey、重复 id——均被保存校验拒绝，错误信息可定位冲突项
- [ ] 单元测试：合法配置 JSON ↔ 内存模型 round-trip 无损（含中文名等非 ASCII）
- [ ] 单元测试：save 走临时文件 + rename；落盘文件权限 `0600`
- [ ] 单元测试：快照交换原子生效——交换后新读请求见新配置，持有旧快照的「请求」不受影响
- [ ] 校验失败的 save 不落盘、不改内存快照
