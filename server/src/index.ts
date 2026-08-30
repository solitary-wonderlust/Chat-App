// 入口：打开 DB、装配应用、监听端口。

import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { openDb } from './db.js';
import { buildApp } from './app.js';

const port = Number(process.env.PORT ?? 3000);
const dbPath = process.env.DB_PATH ?? './data/chat.db';

mkdirSync(dirname(dbPath), { recursive: true });
const db = openDb(dbPath);
const app = await buildApp(db);

app
  .listen({ port, host: '0.0.0.0' })
  .then((addr) => {
    console.log(`chat-app-server listening on ${addr}`);
  })
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
