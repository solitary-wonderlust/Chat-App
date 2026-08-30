# 聊天记录格式规范（契约）

本文件定义聊天记录的**存储模型**与**导入/导出格式**，是后端与 Flutter 客户端共同遵守的契约。

## 1. 设计原则

- **存储不区分用户**：所有用户的消息混存在一张平铺 `messages` 表，靠 `conversation_id → participants` 关联到用户，不做按用户分表/分库。
- **按登录用户区分显示**：用户只能看到自己参与的会话里的消息。
- **幂等合并**：每条记录用全局唯一 `id`（UUID）作为主键，导入/同步统一 `upsert by id`，重复数据被覆盖而非复制。
- **易解析、易合并、易追加**：导出格式为 **JSONL**（JSON Lines），每行一条自描述记录。

## 2. 数据库表结构（本地与服务器完全相同）

```sql
CREATE TABLE users (
  id            TEXT PRIMARY KEY,     -- 用户名即 id
  username      TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  created_at    INTEGER NOT NULL      -- epoch 毫秒
);

CREATE TABLE conversations (
  id           TEXT PRIMARY KEY,      -- UUID
  type         TEXT NOT NULL,         -- 'direct'（现用）| 'group'（预留，未来按需启用）
  name         TEXT,                  -- 群名；direct 会话一般为 null（group 预留）
  participants TEXT NOT NULL,         -- JSON 数组 ["alice","bob"]
  created_at   INTEGER NOT NULL
);

CREATE TABLE messages (
  id              TEXT PRIMARY KEY,   -- 客户端生成的 UUID，去重/合并依据
  conversation_id TEXT NOT NULL,
  sender_id       TEXT NOT NULL,
  type            TEXT NOT NULL,      -- 'text' | 'image' | 'file' | 'system'
  content         TEXT NOT NULL,      -- 文本 / 附件 URL 或本地路径
  created_at      INTEGER NOT NULL,
  edited_at       INTEGER,
  metadata        TEXT                -- JSON，预留扩展
);
CREATE INDEX idx_messages_conversation ON messages(conversation_id, created_at);
```

> `users` 属于账号层，**不参与导出**。记录层只有 `conversations` 与 `messages`，其中的用户通过 `sender_id` / `participants` 里的**用户名**引用。

## 3. 导出格式：JSONL

单文件 `.jsonl`，每行一条自描述记录，用 `record` 字段区分类型。文件内先写所有 `conversation`，再写所有 `message`。

```
{"record":"conversation","id":"uuid-c","type":"direct","name":null,"participants":["alice","bob"],"createdAt":1700000000000}
{"record":"message","id":"uuid-m1","conversationId":"uuid-c","senderId":"alice","type":"text","content":"你好","createdAt":1700000000001,"editedAt":null,"metadata":{}}
{"record":"message","id":"uuid-m2","conversationId":"uuid-c","senderId":"bob","type":"text","content":"Hi","createdAt":1700000000002,"editedAt":null,"metadata":{}}
```

### 字段规范

**conversation 记录**

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `record` | string | 是 | 固定为 `"conversation"` |
| `id` | string(UUID) | 是 | 会话唯一 id |
| `type` | string | 是 | `direct`（现用）\| `group`（预留，客户端当前不创建） |
| `name` | string\|null | 否 | 群名（group 预留；direct 一般为 `null`） |
| `participants` | string[] | 是 | 参与用户名数组 |
| `createdAt` | number | 是 | epoch 毫秒 |

**message 记录**

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `record` | string | 是 | 固定为 `"message"` |
| `id` | string(UUID) | 是 | 消息唯一 id（去重键） |
| `conversationId` | string(UUID) | 是 | 所属会话 |
| `senderId` | string | 是 | 发送者用户名 |
| `type` | string | 是 | `text` \| `image` \| `file` \| `system` |
| `content` | string | 是 | 文本 / 附件路径或 URL |
| `createdAt` | number | 是 | epoch 毫秒 |
| `editedAt` | number\|null | 否 | 编辑时间 |
| `metadata` | object | 否 | 预留，默认 `{}` |

## 4. 导入规则

1. **两遍扫描**：第一遍 upsert 所有 `conversation` 行，第二遍 upsert 所有 `message` 行，避免消息引用未导入的会话。
2. **悬空引用**：若 `message.conversationId` 在文件中不存在且库里也没有，惰性创建一个占位 `direct` 会话（participants 为 `[senderId]`）。
3. **去重**：以 `id` 为主键 `upsert`（存在则覆盖，不存在则插入）。
4. **无 UUID 的第三方记录**：若导入的记录缺 `id`，按 `(conversationId, senderId, content, createdAt)` 生成确定性 UUID（SHA-1），保证重复导入幂等。

## 5. 合并

- 同源导出文件可直接 `cat a.jsonl b.jsonl > merged.jsonl` 后导入，或分别导入，`upsert by id` 保证无重复。
- 跨设备同步本质与合并等价：客户端与服务器使用同一套 UUID 与 upsert 逻辑。
