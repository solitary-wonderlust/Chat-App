# 更新日志

本项目按语义化版本记录。每个阶段对应一次功能交付，详见 [docs/development-plan.md](docs/development-plan.md)。

## 0.1.0（当前，未正式发版）

首个可运行版本：跨平台聊天 App（Flutter 客户端 + 自托管 Node 后端，JSONL 记录层）。核心能力与验证状态如下。

### 功能

- **实时聊天 + 离线优先**：消息先落本地 SQLite 再异步同步（outbox 队列 + WebSocket 推送），断网可发、恢复补同步。
- **存储不区分用户、按登录用户显示**：所有消息混存单张 `messages` 表，查询时按 `participants` 过滤。
- **附件（图片/文件）**：零依赖原始字节上传 + 参与者鉴权下载，`content` 存 `/attachments/<id>/<name>` URL，随 JSONL 往返。
- **消息搜索 + 导出过滤**：`GET /search` 仅搜自己参与的会话；`/export` 支持按发送人 / 时间范围过滤。
- **编辑 / 撤回 / 已读回执**：仅发送者可编辑与撤回（撤回为软删墓碑），已读状态双端同步。
- **导入 / 导出 / 合并**：
  - 统一 JSONL 格式（`record` 区分 conversation/message），UUID + `upsert-by-id` 幂等去重。
  - 设置页「导入 / 导出聊天记录」，导入前预览「新增 / 覆盖 / 相同」条数，可选「跳过已有」或「覆盖已有」。
  - 第三方格式转换：微信 / QQ 导出的 txt 与常见 json 自动转为本格式 JSONL（无 UUID 走确定性 id）。
  - 跨设备合并：「导入到服务器 / 从服务器导出」，A 导出 → B 导入到服务器 → A 同步后可见合并结果。
- **部署**：Docker Compose 一键起服（healthcheck / 数据卷 / 反向代理示例），或直接跑 node。

### 验证

- 后端：42 个测试全绿（单元 + WebSocket 集成 + 端到端），含「双端实时全流程」「跨设备合并无重复」「千条导入 < 1s」。
- 客户端：`flutter analyze` 0 问题，32 个测试全绿（数据层 / 转换器 / 导入合并预览）。
- 编译产物：`tsc` 构建通过，`node dist/index.js` 冒烟（注册 → 建会话 → 发消息 → 导出）通过。
- 真机（OPPO，2026-09-01）：release 包安装 → 启动 → 注册/登录 → 建会话 → 发消息全链路通过。冒烟中发现并修复 release 包缺失 `INTERNET` 权限（Flutter 模板只在 debug manifest 声明）导致无法联网的问题。

### 已知限制

- 群聊完整能力（改群名 / 增删成员）未实现，未来需要时再添加。
- 聊天内容明文存储 / 传输（密码哈希）；生产建议走 HTTPS/WSS。
- 增量拉取游标用「会话内最大 `created_at`」+ `>`，极端同毫秒场景依赖 `id` 幂等兜底。
- 客户端 release 包已构建并在 OPPO 真机跑通核心链路（安装 / 启动 / 注册 / 建会话 / 发消息）；应用名 / 图标为用户本机定制（`咕咕咪咪猫猫王`，不上传仓库），仓库内仍为占位符，见 [docs/development-plan.md](docs/development-plan.md) 阶段 4A。
