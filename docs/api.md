# API 参考

后端 `server/src/routes.ts` 与 `ws.ts` 的接口契约。客户端 `app/lib/api/api_client.dart` 与此一一对应。

## 约定

- Base URL：默认 `http://localhost:3000`（生产经反向代理）。
- 除注册/登录/健康检查外，均需 `Authorization: Bearer <token>`。
- 时间戳均为 epoch 毫秒。
- 错误统一返回 `{ "error": "<消息>" }`，状态码见各接口。

状态码：`400` 参数错误、`401` 未认证、`403` 非会话参与者、`409` 用户名已存在。

## 认证

### POST /auth/register
请求：`{ "username": "alice", "password": "pw" }`
响应 200：`{ "token": "...", "userId": "uuid", "username": "alice" }`
响应 409：用户名已存在。

### POST /auth/login
请求：`{ "username": "alice", "password": "pw" }`
响应 200：`{ "token": "...", "userId": "uuid", "username": "alice" }`
响应 401：凭据错误。

## 会话

### GET /conversations
列出当前用户参与的会话。
响应 200：`[ ConversationRecord, … ]`

### POST /conversations
新建（或按 `id` 幂等覆盖）会话；当前用户自动并入参与者。
请求：`{ "participants": ["bob"], "type": "direct", "name": null, "id": "可选" }`
响应 200：`ConversationRecord`

## 消息

### GET /messages?conversationId=<id>&after=<ts>
增量拉取某会话消息（`created_at > after`）。需为会话参与者。
响应 200：`[ MessageRecord, … ]`

### POST /messages
发送消息（`senderId` 由服务器取当前登录用户，忽略请求里的）。幂等按 `id` upsert。
请求：`{ "conversationId": "…", "type": "text", "content": "hi", "id": "可选", "createdAt": 可选, "metadata": 可选 }`
响应 200：`MessageRecord`

## 导入 / 导出

### GET /export?conversationId=<可选>
导出 JSONL（`application/x-ndjson`）。省略 `conversationId` 导出全量（当前用户参与的会话）。响应体即 [format.md](format.md) 定义的 JSONL 文本。

### POST /import
请求：`{ "text": "<JSONL 文本>" }`
响应 200：`{ "conversations": 3, "messages": 42 }`

## 记录结构

`ConversationRecord` 与 `MessageRecord` 字段见 [format.md](format.md) 第 3 节。

## WebSocket /ws?token=<token>

连接认证失败会 `close(4001)`。

### 客户端 → 服务器

发送消息：
```json
{ "event": "send_message", "conversationId": "…", "type": "text", "content": "hi", "id": "可选", "createdAt": 可选 }
```

新建会话：
```json
{ "event": "create_conversation", "participants": ["bob"], "type": "direct", "name": null, "id": "可选" }
```

### 服务器 → 客户端

新消息：
```json
{ "event": "message", "data": { "record": "message", "id": "…", "conversationId": "…", "senderId": "…", "type": "text", "content": "hi", "createdAt": 1700000000001, "editedAt": null, "metadata": {} } }
```

新会话：
```json
{ "event": "conversation", "data": { "record": "conversation", "id": "…", "type": "direct", "name": null, "participants": ["alice","bob"], "createdAt": 1700000000000 } }
```
