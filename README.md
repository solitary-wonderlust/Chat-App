# 跨平台聊天 App（Flutter + 自托管后端 + JSONL 记录）

iOS / Android 通用聊天 App，核心能力：

- **实时聊天** + **离线优先**：消息先落本地 SQLite 再异步同步，断网可发，恢复补同步。
- **存储不区分用户**：所有用户的消息混存同一张 `messages` 表，靠 `conversation_id → participants` 关联到用户。
- **按登录用户区分显示**：登录后只看到自己参与的会话。
- **易导入 / 导出 / 合并**：统一 JSONL 格式，`upsert-by-id` 幂等去重，两份记录可安全合并。
- **不加密**：聊天内容明文存储/传输（密码仍哈希）。

> 架构、数据模型、JSONL 字段规范见 [docs/format.md](docs/format.md)。

## 目录结构

```
chat-app/
  server/   # Node + TypeScript 后端（Fastify + better-sqlite3 + WebSocket）
  app/      # Flutter 客户端（drift SQLite + riverpod）
  docs/     # 契约文档
```

## 文档

- [docs/format.md](docs/format.md) — 数据模型 + JSONL 格式契约（两端共同遵守）
- [docs/architecture.md](docs/architecture.md) — 架构设计、同步模型、模块边界
- [docs/api.md](docs/api.md) — REST + WebSocket 接口参考
- [docs/development-plan.md](docs/development-plan.md) — 阶段性任务拆解与并行开发指南

## 环境要求

- Node.js ≥ 18（`node` / `npm`）
- Flutter SDK（含 Dart）

## 一、运行后端

```bash
cd server
npm install
npm test          # 跑单测：幂等 upsert / JSONL 往返 / 合并去重 / 多用户隔离
npm run dev       # 开发模式，默认监听 0.0.0.0:3000
```

环境变量（可选）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `3000` | 监听端口 |
| `DB_PATH` | `./data/chat.db` | SQLite 文件路径 |
| `JWT_SECRET` | `dev-secret-change-me` | JWT 签名密钥（生产请务必设置） |

REST 接口（`server/src/routes.ts`）：注册 `/auth/register`、登录 `/auth/login`、会话 `/conversations`、消息 `/messages`、导出 `/export`、导入 `/import`。WebSocket 实时通道 `/ws?token=…`。

## 二、运行 Flutter 客户端

首次需要生成平台脚手架（`android/`、`ios/` 目录）和 drift 代码：

```bash
cd app
flutter create .        # 生成缺失的平台目录（不覆盖 lib/）
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # 生成 database.g.dart
flutter run
```

- **Android 模拟器**访问宿主机后端，服务器地址填 `http://10.0.2.2:3000`（登录页默认值）。
- **iOS 模拟器**填 `http://localhost:3000`（本项目暂不验证 iOS，需 macOS 环境）。
- **真机**填电脑的局域网 IP，如 `http://192.168.1.10:3000`（后端需监听 `0.0.0.0`，已默认）。

登录页输入服务器地址 + 用户名 + 密码，点「注册」创建账号，或「登录」已有账号。

## 三、核心流程与验证

1. **多用户隔离**：注册 alice / bob / carol。alice 新建会话（填 `bob`）并发消息；bob 登录能看到会话和消息；carol 登录看不到。
2. **离线同步**：设备断网发消息 → 消息立刻出现在本地（离线优先）→ 恢复网络后自动推送到服务器（outbox 队列 + WebSocket 推送）。
3. **导入 / 导出 / 合并**：
   - 「设置 → 导出聊天记录」把本地记录导出为 `.jsonl`（走系统分享）。
   - 「设置 → 导入聊天记录」选一个 `.jsonl` 文件导入，按 `id` 去重合并。
   - 手动合并：`cat a.jsonl b.jsonl > merged.jsonl` 后导入，或用服务器 `POST /import` 回灌，重复导入无副本。
4. **后端单测**：`cd server && npm test`，覆盖幂等、往返、合并、隔离。

## JSONL 示例

```
{"record":"conversation","id":"uuid-c","type":"direct","name":null,"participants":["alice","bob"],"createdAt":1700000000000}
{"record":"message","id":"uuid-m1","conversationId":"uuid-c","senderId":"alice","type":"text","content":"你好","createdAt":1700000000001,"editedAt":null,"metadata":{}}
```

完整字段定义见 [docs/format.md](docs/format.md)。

## 已知取舍

- 增量拉取游标用「会话内最大 `created_at`」+ `>`，同一毫秒撞车的极端情况依赖 `id` 幂等兜底；如需绝对不漏，可改为 `after = max - 1`（重取最后一条，仍幂等）。
- 新建会话目前依赖在线（走服务器），离线发消息则完全可用。
- token 存在 `shared_preferences`（明文）；生产可换 `flutter_secure_storage`。
- 附件（图片/文件）`type` 字段已预留，尚未实现上传。
