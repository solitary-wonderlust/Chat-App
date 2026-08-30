// Fastify 应用装配：便于在测试中用 app.inject() 直接注入请求。

import Fastify from 'fastify';
import cors from '@fastify/cors';
import websocket from '@fastify/websocket';
import type { Database } from 'better-sqlite3';
import { registerRoutes } from './routes.js';
import { registerWs } from './ws.js';
import { registerAttachments } from './attachments.js';

export async function buildApp(db: Database) {
  const app = Fastify({ logger: false });
  await app.register(cors, { origin: true });
  // 必须 await：@fastify/websocket 的 onRoute hook 需在注册 /ws 路由前安装，
  // 否则 WebSocket 处理器会被当成普通 HTTP handler 以 (request, reply) 调用。
  await app.register(websocket);
  registerRoutes(app, db);
  registerAttachments(app, db);
  registerWs(app, db);
  return app;
}
