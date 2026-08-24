// Fastify 应用装配：便于在测试中用 app.inject() 直接注入请求。

import Fastify from 'fastify';
import cors from '@fastify/cors';
import websocket from '@fastify/websocket';
import type { Database } from 'better-sqlite3';
import { registerRoutes } from './routes.js';
import { registerWs } from './ws.js';

export function buildApp(db: Database) {
  const app = Fastify({ logger: false });
  app.register(cors, { origin: true });
  app.register(websocket);
  registerRoutes(app, db);
  registerWs(app, db);
  return app;
}
