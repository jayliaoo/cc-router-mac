# 06: App 壳：Xcode 工程 + 菜单栏 UI

**做什么：** 出现一个能日常使用的 macOS app：菜单栏常驻静态图标，popover 里有网关主开关和各 Provider 的启用开关，扳动开关立即热生效；app 启动恢复上次主开关状态；端口被占用时明确报错。

**阻塞于：** 03（网关核心行为就绪）。

**状态：** 完成（手测项留待发起人验收）

## 上下文

- **相关用户故事**：spec 14（主开关启停）、15（provider 独立开关）、19（启动恢复主开关状态）、21（热生效）、22（端口占用明确报错）、24（静态图标 + popover）。
- **设计决策**（自 design「1.3 / 2.2」摘录）：
  - 工程结构（已确认）：核心逻辑在本地 SPM library（任务 01 建），本任务新建 **Xcode app target** 引用该包，app 壳只做 UI 与生命周期编排。构建选型已确认：Xcode 工程（pbxproj 入库）而非手工打 bundle——菜单栏 app 需要 Info.plist（`LSUIElement`，不进 Dock）、签名，登录自启（SMAppService）对 bundle 有硬要求。
  - UI：SwiftUI `MenuBarExtra`（macOS 13+），**静态图标**（不区分状态）；popover：主开关 + Provider 列表（名称 + 各自启用开关）。
  - 所有开关/编辑经 ConfigStore 换快照 + 持久化；主开关变更即网关 server start/stop，provider 开关变更热生效（在途请求不受影响）。
  - 监听生命周期（design 5.3）：主开关 on → 起 listener；off → 停止接受新连接，在途自然走完；**端口被占用 → 启动失败，UI 明确报错，主开关回落为 off**。
  - 最低 macOS 13；**本机 macOS 27 / Xcode 27.1 为第一验证环境**（spec 约束）。
- **seam 约定**（design「6.2」）：**UI 不做自动化测试**，手工验证；本任务不新增 seam，核心行为已由任务 01–05 的端到端测试覆盖。
- **附带产物**：把本任务确立的构建/运行/测试命令（如 `xcodebuild` 参数、核心包 `swift test`）补进根目录 CLAUDE.md 的「仓库现状」一节，替换其中「尚无构建命令」的表述。

## 验收标准

- [x] `xcodebuild`（或 Xcode GUI）能构建出可运行的菜单栏 app（LSUIElement，不进 Dock）
- [ ] 手测：菜单栏出现静态图标；主开关开启后网关可被 HTTP 客户端访问；关闭后连接被拒
- [ ] 手测：provider 启用开关切换立即改变路由（配合一个假上游或真实上游），无需重启
- [ ] 手测：退出并重启 app，主开关恢复上次状态（上次开 → 本次启动网关自动开）
- [ ] 手测：占用端口（如另起进程监听同端口）后开主开关 → UI 明确报错且主开关回落 off
- [x] CLAUDE.md 已记录构建/测试命令
- [x] 核心包测试（`swift test`）保持绿色
