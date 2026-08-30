# 开发计划与任务拆解

面向**阶段性开发 + 多 agent 并行**。每个 workstream 有独立的文件所有权、依赖与验收标准（DoD），可交给一个 agent 单独完成。

## 并行开发原则

1. **按文件所有权划分**（见 [architecture.md](architecture.md) §8），最小化 merge 冲突。
2. **契约先行**：跨端改动先更新 [format.md](format.md)（数据/JSONL）或 [api.md](api.md)（接口），两端再各自实现。
3. **共享文件冲突**：`server/src/{routes,store,service}.ts`、`app/lib/{service,state}.dart`、`app/lib/ui/*` 是热点。多个 workstream 若都要改同一文件，用 **worktree 隔离**（`EnterWorktree`）或**顺序 handoff**。
4. **可独立验收**：每个 workstream 完成后能单独测试/演示，不依赖同阶段其它 workstream。

## 阶段总览

| 阶段 | 主题 | 并行 workstream |
|---|---|---|
| 0 | 契约 + 骨架 | ✅ 已完成 |
| 1 | 跑通与硬化 | ✅ 已完成（1A 后端测试 · 1B 客户端跑通 · 1C 部署 · 1D 文档） |
| 2 | 核心功能 | ✅ 已完成（2A 附件 · 2B 搜索/导出过滤 · 2C 编辑/撤回/已读回执） |
| 3 | 导入导出体验 | ✅ 已完成（3A 服务器互导 UI · 3B 第三方转换器 · 3C 合并预览） |
| 4 | 发布打磨 | 4B E2E · 4C 发布文档 ✅；4A 打包待用户决策 |

---

## 阶段 0 — 契约 + 骨架（已完成）

- `docs/format.md` 契约、`server/` 完整后端（含单测）、`app/` Flutter 数据层 + 基础 UI。

---

## 阶段 1 — 跑通与硬化

> 目标：把当前代码跑起来、验证正确、具备部署与 CI 基础。四个 workstream 完全独立，可同时开工。

### 1A 后端测试补全
- **文件**：`server/tests/*`（新增）
- **内容**：WS 集成测试（双连接收发广播）、错误路径（403/409/401）、`/export?conversationId=` 过滤、并发 upsert 幂等。
- **依赖**：无。
- **DoD**：`npm test` 全绿；覆盖新增边界用例。

### 1B 客户端跑通与修复
- **文件**：`app/`（运行验证，必要时修 drift 生成/API 细节）
- **内容**：`flutter create .` → `pub get` → `build_runner build` → 模拟器跑通登录/发消息；补 2~3 个 widget 测试（会话过滤、发送入 outbox）。
- **依赖**：需后端 1A 或本地起后端配合。
- **DoD**：Android 模拟器跑通发消息；widget 测试通过。（iOS 不验证）

### 1C 部署与配置
- **文件**：`server/Dockerfile`、`docker-compose.yml`、`server/.env.example`、`docs/deployment.md`
- **内容**：后端容器化、SQLite 数据卷、环境变量文档、反向代理示例。
- **依赖**：无。
- **DoD**：`docker compose up` 一键起后端，健康检查通过。

### 1D 文档完善
- **文件**：`README.md`、`docs/architecture.md`、`docs/api.md`（已有，补漏）
- **内容**：贡献指南、故障排查（drift 生成、10.0.2.2 网络）、CLAUDE.md 维护说明。
- **依赖**：无。
- **DoD**：新开发者按 README 从零跑通。

---

## 阶段 2 — 核心功能增强（已完成）

> 目标：补齐「聊天 App」该有的能力。三个 workstream 主要落在不同文件，热点处需隔离。
>
> 群聊完整能力（改群名、增删成员）已从本期移除：需求不明确，**未来需要时再添加**（见下方「未来延后项」）。
>
> 完成状态（2026-08-31）：
> - ✅ 2A 附件：`POST/GET /attachments`（零依赖原始字节上传 + 参与者鉴权下载）、客户端拍照/相册/文件 + 按 type 渲染气泡。服务端 27 测试 / 客户端 5 测试。
> - ✅ 2B 搜索/导出过滤：`GET /search`（仅搜自己参与的会话）、`/export` 增 `senderId/from/to`；客户端搜索页 + 导出过滤 sheet。服务端 34 / 客户端 9。
> - ✅ 2C 编辑/撤回/已读回执：`PATCH/DELETE /messages/:id`（仅发送者，撤回=软删墓碑）、`/conversations/:id/read` + `read_receipts` 表；客户端长按菜单/已撤回/已读未读。服务端 39 / 客户端 12。
>
> 待办：真机 OPPO 冒烟（附件/搜索/过滤导出/编辑撤回已读）、`docker compose up` 部署验证。

### 2A 附件（图片/文件）
- **契约**：`docs/api.md` 增 `/attachments` 上传与静态下载；`format.md` 明确 `type:image/file` 的 `content` 存 URL。
- **后端文件**：`server/src/attachments.ts`（新增）、`server/src/app.ts`（挂静态）、`store.ts` 不动。
- **客户端文件**：`app/lib/api/api_client.dart`（新增方法）、`app/lib/ui/chat_page.dart`（选图/选文件/预览）。
- **DoD**：发一张图，双端可见；导出 JSONL 里 content 为 URL，导入后可访问。

### 2B 消息搜索 + 导出过滤
- **文件**：`server/src/store.ts` + `routes.ts`（搜索/过滤查询）、`app/lib/ui/settings_page.dart`（导出范围选项）。
- **内容**：按关键词搜消息；导出按「用户 / 会话 / 时间范围」过滤（`/export` 增加参数）。
- **DoD**：搜索结果命中；过滤导出后导入结果正确。

### 2C 消息编辑 / 删除 / 已读回执
- **文件**：`server/src/routes.ts` + `service.ts` + `store.ts`（编辑/删除端点）、`app/lib/service.dart` + `app/lib/ui/chat_page.dart`。
- **内容**：编辑（更新 `edited_at` + 广播）、删除（软删/撤回）、已读（`metadata.read` 或独立 `read_receipts` 表）。
- **DoD**：编辑/撤回实时同步；已读状态双端一致。

### 未来延后项：群聊完整能力（本期不做）
> 群聊本期不需要，**未来需要时再添加**，条目如下，届时按此启用即可：
- **文件**：`server/src/routes.ts` + `store.ts`（成员/群名变更）、`app/lib/ui/home_page.dart` + 新增 `app/lib/ui/group_settings_page.dart`。
- **内容**：改群名、增删成员、群信息展示。
- **DoD**：群名/成员变更实时广播给群成员；会话列表正确显示。

> 2A/2B/2C 都触及 `routes.ts` 与 `chat_page.dart`：建议 2A 与 2C 分属不同层（后端附件 vs 客户端交互）用 worktree 隔离，或按「先后端契约、再客户端」两波推进。

---

## 阶段 3 — 导入导出与合并体验

> 完成状态（2026-08-31）：
> - ✅ 3A 服务器互导：设置页「导入到服务器（跨设备合并）」/「从服务器导出」入口 + 进度弹窗；复用既有 `/import` `/export`（客户端早前已具备 `importToServer` / `exportFromServer`）。客户端测试 13。
> - ✅ 3B 第三方转换器：`app/lib/import_export/converters/` 独立实现，微信/QQ 常见 txt 与 json → 本格式 JSONL（无 UUID 走确定性 id；`me` 并入 participants 保证导入后可见）。样例 `app/test/fixtures/{wechat,qq}.txt`、`wechat.json`。客户端测试 11。
> - ✅ 3C 合并预览与冲突：`previewImport` 区分「新增 / 覆盖（内容不同）/ 相同」，`importJsonl(mode: overwrite|skipExisting)`；导入前弹预览 sheet 选「跳过已有 / 覆盖已有」。客户端测试 6。
> - ✅ 客户端 `flutter analyze` 0 问题；客户端测试 32/32、服务端测试 39/39 全绿（本阶段未改服务端）。
>
> 待办验证（需用户）：真机 OPPO 冒烟补测「A 导出 → B 导入到服务器 → A 同步可见合并结果」；`docker compose up` 部署验证。

### 3A 服务器互导 UI
- **文件**：`app/lib/ui/settings_page.dart`、`app/lib/service.dart`
- **内容**：设置页加「从服务器导出 / 导入到服务器」入口 + 进度/结果提示。
- **DoD**：跨设备：A 导出 → B 导入到服务器 → A 客户端同步后可见合并结果。

### 3B 第三方格式转换器
- **文件**：`app/lib/import_export/converters/`（新增，独立于现有 jsonl.dart）
- **内容**：把微信/QQ 等导出的 txt/json 转成本格式 JSONL（无 UUID 走确定性 id）。
- **DoD**：一份样例第三方导出能转成合法 JSONL 并导入去重。

### 3C 合并预览与冲突处理
- **文件**：`app/lib/import_export/`（新增 preview 逻辑）、`app/lib/ui/`（预览页）
- **内容**：导入前预览「新增/覆盖」条数，支持选择「跳过已有 / 覆盖」。
- **DoD**：导入前可见差异；选择跳过时已有记录不被覆盖。

---

## 阶段 4 — 发布打磨

> 完成状态（2026-08-31）：
> - ✅ 4B 端到端与性能：`server/tests/e2e/e2e.test.ts` 真实端口 + HTTP fetch + WebSocket 全流程。3 个测试覆盖「双端实时（广播/编辑/撤回/已读/附件鉴权）」「导出→导入→再同步无重复」「千条导入 < 1s」。顺带修复了既有的 `src/export.ts` 漏 import 导致的 `tsc` 构建失败。服务端测试 42/42、`npm run build` 通过、编译产物冒烟通过。
> - ✅ 4C 发布文档：新增 `CHANGELOG.md`；README 补「升级」一节与 CHANGELOG 链接；`docs/deployment.md` 补直接跑 node 的升级说明。
> - ⏳ 4A 打包配置（**待用户决策**）：应用名/图标/签名需用户拍板，release 包需真机 OPPO 验证（[[dev-env-windows]]），本次未做。

### 4A 打包配置
- **文件**：`app/android/`、图标/启动页
- **内容**：应用名、图标、签名、release 构建（Android；iOS 暂不验证）。
- **DoD**：Android release 包可安装运行。

### 4B 端到端测试与性能
- **文件**：`server/tests/e2e/`（新增）、`app/test/`
- **内容**：双端联调脚本；大批量消息下的同步/导入性能。
- **DoD**：千条消息导入 < 秒级、同步无重复。

### 4C 发布文档
- **文件**：`README.md`、`docs/deployment.md`、`CHANGELOG.md`
- **内容**：安装/部署/使用/升级说明。
- **DoD**：用户与运维按文档可独立完成部署与使用。

---

## 建议的并行 agent 编排

> 资源限制：**本机最多同时 2 个 agent 并行**。所有阶段都按「每次最多 2 个」分批推进。

- **阶段 1**（零冲突，分两批）：批 1 = 1A 后端测试 + 1B 客户端跑通；批 2 = 1C 部署 + 1D 文档。
- **阶段 2**：优先按「后端契约 + 后端实现」与「客户端实现」分成 2 个 agent；共享文件用 worktree 隔离后再并行。
- **阶段 3**：3A/3B/3C 文件基本独立，任意 2 个并行，第 3 个接续。
- **阶段 4**：4A 打包 + 4C 发布文档并行；4B 依赖阶段 2 完成后再做。
