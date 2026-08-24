# 架构设计

## 1. 概览

双端应用：**Flutter 客户端**（iOS/Android）+ **自托管 Node 后端**。核心原则是「离线优先 + UUID 幂等 + JSONL 记录」。

```
┌───────────────────────────────┐         ┌──────────────────────────────┐
│  Flutter App (iOS/Android)    │  WSS    │  自托管后端 (Node + TS)       │
│                               │◄───────►│                              │
│  drift SQLite（本地主存）     │  REST   │  better-sqlite3（WAL）        │
│  ├ 先落本地，再异步同步       │◄───────►│  ├ 单表 messages（不分用户）  │
│  ├ outbox 离线队列            │         │  ├ upsert-by-id 幂等          │
│  ├ 按登录用户过滤查询         │         │  └ WebSocket 广播会话成员     │
│  └ JSONL 导入/导出            │         └ JSONL 导入/导出              │
└───────────────────────────────┘         └──────────────────────────────┘
```

## 2. 组件与职责

| 组件 | 位置 | 职责 |
|---|---|---|
| 后端入口 | `server/src/index.ts` | 打开 DB、监听端口 |
| 应用装配 | `server/src/app.ts` | Fastify + CORS + WebSocket 注册，便于 `inject` 测试 |
| 数据层 | `server/src/db.ts` + `store.ts` | 建表 + 幂等 upsert + 查询 |
| JSONL 编解码 | `server/src/format.ts` | 记录 ↔ JSONL 行（与客户端逐字一致） |
| 导入/导出 | `server/src/export.ts` | 两遍扫描导入、按 id 去重 |
| 认证 | `server/src/auth.ts` | scrypt 哈希 + HMAC-JWT |
| 业务服务 | `server/src/service.ts` | 新建记录 + 广播（REST/WS 共用） |
| 路由 | `server/src/routes.ts` | REST 接口 |
| 实时 | `server/src/ws.ts` + `hub.ts` | WS 通道 + 按用户推送注册表 |
| 客户端 DB | `app/lib/db/` | drift 表 + DAO（记录层与服务器一致 + outbox） |
| JSONL | `app/lib/import_export/jsonl.dart` | 与服务器 `format.ts` 逐字一致 |
| API 客户端 | `app/lib/api/api_client.dart` | REST 封装 |
| 登录态 | `app/lib/auth/session.dart` | token/用户/服务器地址持久化 |
| 核心服务 | `app/lib/service.dart` | 发消息/同步/导入导出编排 |
| 依赖注入 | `app/lib/state.dart` | Riverpod provider |
| UI | `app/lib/ui/` | 登录/会话/聊天/设置 |

## 3. 数据模型

见 [format.md](format.md)。要点：`messages` 是**一张平铺表**，所有用户的消息混存，通过 `conversation_id → conversations.participants`（JSON 数组）关联到用户。

- 「不区分用户存储」= 不做按用户分表/分库。
- 「按登录用户区分显示」= 查询时 `participants.includes(userId)` 过滤。

`users` 属账号层，不参与导出；记录层只有 `conversations` 与 `messages`。

## 4. 同步模型（离线优先）

1. **发送**：客户端生成 UUID → 先写本地 `messages` → 同时入 `outbox` → 异步推送服务器 → 成功删 outbox。
2. **推送**：`outbox` 队列逐条 `POST /messages`（幂等 upsert），失败（离线）中断留待下次。
3. **拉取**：逐会话增量拉取，游标 = 本地该会话 `MAX(created_at)`，`GET /messages?after=…`。
4. **实时**：WS `/ws?token=`，服务端把新消息/新会话推给在线参与者；断线 3 秒重连。

**幂等合并**：全局唯一 UUID + `INSERT … ON CONFLICT(id) DO UPDATE`，重复推送/导入/合并都不会产生副本。

## 5. 导入 / 导出 / 合并

- 统一 JSONL，单文件，每行一条自描述记录（`record` 字段区分 conversation/message）。
- 导出：先 conversation 行，再 message 行。
- 导入：两遍扫描（conversation 先于 message）；悬空 `conversationId` 惰性建占位 direct 会话；无 id 的第三方记录按 `(conversationId, senderId, content, createdAt)` 生成 SHA-1 确定性 id。
- 合并：`cat a.jsonl b.jsonl` 后导入，或分别导入，upsert-by-id 保证无重复。

## 6. 认证

- 密码：`node:crypto` scrypt（`salt:hash`），零外部依赖。
- Token：HMAC-SHA256 JWT（不依赖 jsonwebtoken），`Authorization: Bearer <token>`。
- 聊天内容按需求明文；密码仍哈希。

## 7. 关键设计决策

| 决策 | 理由 |
|---|---|
| JSONL 而非 JSON 数组 / SQLite 文件 | 可流式逐行解析、`cat` 即可合并、可追加、肉眼可读 |
| UUID 主键 + upsert-by-id | 同步与合并天然幂等 |
| 单表 messages + participants 过滤 | 直接满足「不区分用户存储、按用户显示」 |
| 本地与服务器同 schema + 同 JSONL | 两端可互导、可互同步 |
| outbox 独立表（不污染 messages） | 记录层两端 schema 完全一致 |

## 8. 模块边界（并行开发的关键）

为避免并行 agent 产生 merge 冲突，按以下边界划分所有权：

| 边界 | 文件 | 说明 |
|---|---|---|
| 后端数据/编解码 | `server/src/{db,store,format,export}.ts` + `types.ts` | 契约层，改动需同步客户端 `jsonl.dart` |
| 后端接口 | `server/src/{routes,service,ws,hub,auth}.ts` | 改动需同步 `docs/api.md` |
| 客户端数据层 | `app/lib/{db,import_export,api,auth}` | 契约层，改动需同步后端 |
| 客户端编排 | `app/lib/{service,state}.dart` | 依赖数据层，不改 UI |
| 客户端 UI | `app/lib/ui/*` + `main.dart` | 只依赖 service/state 的公开接口 |
| 文档 | `docs/*` `README.md` | 独立 |
