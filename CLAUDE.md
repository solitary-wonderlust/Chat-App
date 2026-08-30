# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目是什么

跨平台聊天 App：Flutter 客户端（iOS/Android）+ 自托管 Node 后端。核心诉求：实时聊天 + 离线优先 + 聊天记录「不区分用户存储、按登录用户显示」+ JSONL 易导入/导出/合并 + 不加密。完整架构见 [docs/architecture.md](docs/architecture.md)。

## 本机环境约束

- 本机 C 盘空间有限：依赖下载、构建产物、缓存等能放 D:/E: 盘的尽量放 D:/E:，不要下载/生成到 C 盘。相关既有配置：`PUB_CACHE` 在 E:、Gradle 用阿里云镜像（见 memory `dev-env-windows`、`china-gradle-network`）。

## 常用命令

后端（`server/`，Node + TypeScript + Fastify + better-sqlite3）：

```bash
cd server && npm install        # 装依赖
npm test                        # 跑全部单测（node:test + tsx）
npx tsx --test tests/format.test.ts   # 跑单个测试文件
npm run dev                     # 开发模式，默认监听 0.0.0.0:3000
npm run build && npm start      # 编译并运行产物
```

客户端（`app/`，Flutter + drift + riverpod）：

```bash
cd app && flutter create .      # 首次：生成 android/ ios/ 平台目录（不覆盖 lib/）
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # 生成 drift 代码
flutter run
flutter test test/xxx_test.dart  # 单个测试
```

## 架构（大图）

两端共享同一套「记录层」模型与 JSONL 格式（契约见 [docs/format.md](docs/format.md)）：

- **存储不区分用户**：所有消息混存单张 `messages` 表；`conversations.participants` 是 JSON 数组。按登录用户显示 = 查询时 `participants.includes(userId)` 过滤。
- **幂等合并**：每条记录用客户端生成的 UUID 主键，`upsert-by-id`（`INSERT … ON CONFLICT(id) DO UPDATE`）。同步、导入、合并共用这一条路径。
- **离线优先同步**：发消息先落本地 `messages` + `outbox`，再异步 `POST /messages`；拉取用「会话内 `MAX(created_at)`」作游标增量；WebSocket `/ws?token=` 实时推送给会话参与者。
- **导入/导出**：统一 JSONL，单文件每行一条自描述记录（`record` 字段区分 conversation/message）。导入两遍扫描（conversation 先于 message）。

## 关键不变量（改动前必读）

1. **JSONL 编解码有两份，必须逐字一致**：`server/src/format.ts` ↔ `app/lib/import_export/jsonl.dart`，另有契约 `docs/format.md`。改格式要三处同步。
2. **确定性 id 的分隔符是 NUL**：两处 `deterministicId` 都用 `String.fromCharCode(0)`。勿换成普通可见字符而不改另一端。
3. **客户端 `messages`/`conversations` 表与服务器 schema 完全一致**；`outbox` 是客户端专属，绝不能进入导出。
4. **drift 是代码生成**：`app/lib/db/database.g.dart` 由 build_runner 生成，改 `tables.dart` 后必须重跑 `build_runner`。
5. **接口契约在 [docs/api.md](docs/api.md)**：`server/src/routes.ts` + `ws.ts` 与 `app/lib/api/api_client.dart` 一一对应。

## 模块边界（并行开发）

文件所有权划分见 [docs/architecture.md](docs/architecture.md) §8。要点：

- 改「数据/JSONL」层 → 两端同步（server/src/{db,store,format,export}.ts ↔ app/lib/{db,import_export}）。
- 改「接口」层 → 同步 `docs/api.md`。
- UI（`app/lib/ui/*`）只依赖 `service.dart`/`state.dart` 的公开接口。
- 热点文件（`routes.ts` / `store.ts` / `service.dart` / `chat_page.dart`）多 agent 并行时用 worktree 隔离。

阶段性任务拆解见 [docs/development-plan.md](docs/development-plan.md)。
