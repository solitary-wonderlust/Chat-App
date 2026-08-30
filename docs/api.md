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

### PATCH /messages/:id
编辑消息。仅**发送者**可编辑，且仅 `text` 类型、未撤回的消息。
请求：`{ "content": "新内容" }`
响应 200：更新后的 `MessageRecord`（`editedAt` 被设置）。
`404` 不存在；`403` 非参与者 / 非发送者；`400` 内容为空、非 text、或已撤回。

### DELETE /messages/:id
撤回消息（**软删墓碑**）。仅**发送者**可撤回。删除后 `content` 清空（附件 URL 一并失效）、`metadata.deleted = true`，行仍保留以维持合并幂等。
响应 200：墓碑后的 `MessageRecord`。
`404` 不存在；`403` 非参与者 / 非发送者。

## 已读回执

### GET /conversations/:id/read
某会话所有参与者的已读游标。需为参与者。
响应 200：`[{ "username": "alice", "upTo": 1700000000000 }, …]`

### POST /conversations/:id/read
上报当前用户在会话的已读游标（`upTo` = 已读到的最大消息 `created_at`），upsert 并广播给参与者。
请求：`{ "upTo": 1700000000000 }`
响应 200：`{ "ok": true, "upTo": … }`
`403` 非参与者；`400` 缺 `upTo`。

## 附件

### POST /attachments
上传附件（**原始字节**，非 multipart）。需登录。上限 25 MB。
请求：
- body：文件原始字节
- `Content-Type`：文件 mime（如 `image/jpeg`）
- `x-filename`：文件名，URL 编码（`encodeURIComponent`）

响应 201：`{ "url": "/attachments/<id>/<name>", "name": "…", "size": 123, "mime": "image/png" }`
- `url` 是**服务器相对路径**，客户端用 `serverUrl + url` 拼全；作为消息 `content` 存储。
- 空 body → 400；超限 → 413；未认证 → 401。

### GET /attachments/:id/:name
下载附件。需登录，且必须为**引用该附件消息所在会话的参与者**。
响应 200：文件字节，`Content-Type` 为上传时的 mime。
未认证 → 401；非参与者 → 403；不存在 → 404。

## 导入 / 导出

### GET /search?q=<关键词>&conversationId=<可选>&from=<可选>&to=<可选>
按关键词搜消息。**只搜当前用户参与的会话**（「按登录用户区分显示」），纯子串匹配、ASCII 大小写不敏感。
- `q`：必填，关键词；空 → 400。
- `conversationId`：可选，限定会话（需为参与者，否则 403）。
- `from` / `to`：可选，`created_at` 时间范围（epoch 毫秒）。

响应 200：`[ MessageRecord, … ]`（`created_at` 升序）。未认证 → 401。

### GET /export?conversationId=<可选>&senderId=<可选>&from=<可选>&to=<可选>
导出 JSONL（`application/x-ndjson`）。省略 `conversationId` 导出全量（当前用户参与的会话）。
- `senderId`：可选，只导出该发送者的消息。
- `from` / `to`：可选，`created_at` 时间范围（epoch 毫秒）。

有消息级过滤时，只导出**至少含一条命中消息**的会话（不含空会话壳）。响应体即 [format.md](format.md) 定义的 JSONL 文本。

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

新消息 / 编辑后的消息 / 撤回墓碑（同一事件，客户端按记录 upsert 即可）：
```json
{ "event": "message", "data": { "record": "message", "id": "…", "conversationId": "…", "senderId": "…", "type": "text", "content": "hi", "createdAt": 1700000000001, "editedAt": null, "metadata": {} } }
```

已读回执：
```json
{ "event": "read", "data": { "conversationId": "…", "username": "alice", "upTo": 1700000000001 } }
```

新会话：
```json
{ "event": "conversation", "data": { "record": "conversation", "id": "…", "type": "direct", "name": null, "participants": ["alice","bob"], "createdAt": 1700000000000 } }
```
