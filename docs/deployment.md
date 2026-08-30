# 部署指南

后端是 Node + TypeScript + Fastify + better-sqlite3（单文件 SQLite）。部署方式二选一：**Docker Compose（推荐）**或**直接跑 node**。

## 一、Docker Compose（推荐）

### 前提

- Docker + Docker Compose（本机需自行安装；开发机没装 Docker 时只能用「直接跑 node」）。
- 数据用命名卷持久化，容器重建不丢。

### 快速开始

```bash
cd server
cp .env.example .env            # 首次
# 编辑 .env，把 JWT_SECRET 改成随机长字符串：
#   openssl rand -hex 32
docker compose up -d --build
docker compose ps               # 状态应 healthy
curl http://localhost:3000/health   # 期望 {"ok":true}
```

端口：宿主机 3000 → 容器 3000（`docker-compose.yml` 里可改）。

### 数据卷

- SQLite 文件在容器内 `/app/data/chat.db`，挂载自命名卷 `chat-data`。
- 备份：`docker compose stop` 后复制卷内容，或用 `docker cp <container>:/app/data/chat.db ./backup/`。
- 恢复：把备份放回卷内同路径再启动。
- 想让数据直接落宿主机目录（便于查看/备份），可把卷改为 bind mount：
  ```yaml
  volumes:
    - /absolute/path/to/data:/app/data
  ```
  bind mount 时目录权限需为 `node` 用户可写（UID 1000），Windows 上通常直接可用。

### 升级

```bash
docker compose build --pull && docker compose up -d
```

### 常见问题

- **国内拉 `node:22-bookworm-slim` 慢**：给 Docker daemon 配 registry mirror，或换成可访问的镜像 tag。
- **`npm ci` 慢/失败**：构建时可换 npm 镜像源：
  ```bash
  docker compose build --build-arg NPM_REGISTRY=https://registry.npmmirror.com
  ```
- 健康检查打 `GET /health`（[routes.ts](../server/src/routes.ts)），服务起来了就 `{"ok":true}`。

## 二、直接跑 Node（无 Docker）

```bash
cd server
npm install
npm run build
node dist/index.js              # 等价 npm start
```

环境变量（默认值见下，启动时生效）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `3000` | 监听端口（始终绑定 `0.0.0.0`） |
| `DB_PATH` | `./data/chat.db` | SQLite 文件路径（目录不存在会自动创建） |
| `JWT_SECRET` | `dev-secret-change-me` | JWT 签名密钥，**生产必须设置** |

示例：

```bash
JWT_SECRET=$(openssl rand -hex 32) PORT=8080 DB_PATH=/srv/chat/chat.db node dist/index.js
```

建议用 systemd / pm2 / 进程守护托管，配日志轮转。

**升级**：`git pull` → `npm install` → `npm run build` → 重启服务进程；`DB_PATH` 指向原数据文件即可，升级不丢数据。跨大版本先看 [CHANGELOG.md](../CHANGELOG.md) 确认格式 / 接口是否有破坏性变更。

## 三、反向代理（HTTPS / WSS）

客户端用 WebSocket 实时推送，反向代理需同时转发 HTTP 与 WebSocket 升级头。Nginx 示例：

```nginx
server {
  listen 443 ssl;
  server_name chat.example.com;
  # ssl_certificate / ssl_certificate_key ...

  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 300s;   # 长连接，避免 WS 被过早断开
  }
}
```

HTTP 流量（可选）重定向到 HTTPS，避免明文聊天内容裸奔。

## 四、备份与恢复（记录层）

- **导出**：登录后走客户端「设置 → 导出聊天记录」，或 `GET /export`（带 token）拿 JSONL。
- **导入**：客户端「设置 → 导入」，或 `POST /import` 回灌。
- JSONL 用 UUID + upsert-by-id，**跨服务器迁移**只需导出一份 JSONL 灌进新服务器即可，不用搬 SQLite 文件。

## 五、安全提醒

- 聊天内容按需求**不加密**：要么只在可信内网/自签 HTTPS 上跑，要么将来加端到端加密。
- `JWT_SECRET` 泄露 = 可伪造任意用户 token，务必设强随机值并妥善保管。
