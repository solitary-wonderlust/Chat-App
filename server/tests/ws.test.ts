// WebSocket 集成测试：双连接广播、非参与者隔离、认证失败 close(4001)。
// 用真实 ws 客户端连到临时监听的端口（app.inject 无法覆盖 WebSocket 升级）。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import type { AddressInfo } from 'node:net';
import type { FastifyInstance } from 'fastify';
import { openDb } from '../src/db.js';
import { buildApp } from '../src/app.js';

interface App {
  db: ReturnType<typeof openDb>;
  app: FastifyInstance;
  port: number;
}

async function startApp(): Promise<App> {
  const db = openDb();
  const app = await buildApp(db);
  await app.listen({ port: 0, host: '127.0.0.1' });
  const addr = app.server.address() as AddressInfo | null;
  return { db, app, port: addr ? addr.port : 0 };
}

async function register(app: FastifyInstance, username: string) {
  const res = await app.inject({
    method: 'POST',
    url: '/auth/register',
    payload: { username, password: 'pw123456' },
  });
  assert.equal(res.statusCode, 200, `register ${username}`);
  return res.json() as { token: string; userId: string };
}

function auth(token: string) {
  return { authorization: `Bearer ${token}` };
}

async function createConversation(app: FastifyInstance, token: string, withUser: string) {
  const res = await app.inject({
    method: 'POST',
    url: '/conversations',
    headers: auth(token),
    payload: { participants: [withUser], type: 'direct' },
  });
  assert.equal(res.statusCode, 200);
  return res.json() as { id: string; participants: string[] };
}

/** 连接并等待 open。 */
function connect(port: number, token: string): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${encodeURIComponent(token)}`);
    ws.on('open', () => resolve(ws));
    ws.on('error', (e) => reject(e));
  });
}

/** 等待下一条消息，超时抛错。 */
function nextMessage(ws: WebSocket, timeoutMs = 2000): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.off('message', onMsg);
      reject(new Error('timeout waiting for ws message'));
    }, timeoutMs);
    function onMsg(raw: WebSocket.RawData) {
      clearTimeout(timer);
      ws.off('message', onMsg);
      resolve(JSON.parse(raw.toString()) as Record<string, unknown>);
    }
    ws.on('message', onMsg);
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

test('WebSocket：参与者收到广播，非参与者收不到', async (t) => {
  const { db, app, port } = await startApp();
  t.after(async () => {
    await app.close();
    db.close();
  });

  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const carol = await register(app, 'carol');
  const conv = await createConversation(app, alice.token, 'bob');

  const wsAlice = await connect(port, alice.token);
  const wsBob = await connect(port, bob.token);
  const wsCarol = await connect(port, carol.token);
  t.after(() => {
    wsAlice.close();
    wsBob.close();
    wsCarol.close();
  });

  // carol 非参与者，不应收到任何广播
  let carolGot = false;
  wsCarol.on('message', () => {
    carolGot = true;
  });

  // alice 通过 WS 发消息
  const bobMsg = nextMessage(wsBob);
  wsAlice.send(
    JSON.stringify({
      event: 'send_message',
      conversationId: conv.id,
      type: 'text',
      content: 'hi bob',
      id: 'ws-msg-1',
      createdAt: 1700000000000,
    }),
  );

  const msg = await bobMsg;
  assert.equal(msg.event, 'message');
  const data = msg.data as Record<string, unknown>;
  assert.equal(data.id, 'ws-msg-1');
  assert.equal(data.conversationId, conv.id);
  assert.equal(data.senderId, 'alice');
  assert.equal(data.content, 'hi bob');
  assert.equal(data.type, 'text');

  // 短暂等待，确认 carol 没收到
  await sleep(300);
  assert.equal(carolGot, false);
});

test('WebSocket：非参与者经 WS 发消息被忽略（不落库、不广播）', async (t) => {
  const { db, app, port } = await startApp();
  t.after(async () => {
    await app.close();
    db.close();
  });

  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const carol = await register(app, 'carol');
  const conv = await createConversation(app, alice.token, 'bob');

  const wsAlice = await connect(port, alice.token);
  const wsCarol = await connect(port, carol.token);
  t.after(() => {
    wsAlice.close();
    wsCarol.close();
  });

  let aliceGot = false;
  wsAlice.on('message', () => {
    aliceGot = true;
  });

  // carol（非参与者）尝试发消息，应被静默忽略
  wsCarol.send(
    JSON.stringify({
      event: 'send_message',
      conversationId: conv.id,
      type: 'text',
      content: 'sneaky',
      id: 'sneaky-1',
    }),
  );

  await sleep(300);
  assert.equal(aliceGot, false);

  // 落库也不应有这条消息
  const msgs = await app.inject({
    method: 'GET',
    url: `/messages?conversationId=${conv.id}`,
    headers: auth(alice.token),
  });
  assert.equal((msgs.json() as unknown[]).length, 0);
});

test('WebSocket：无效 token 连接被拒（close 4001）', async (t) => {
  const { db, app, port } = await startApp();
  t.after(async () => {
    await app.close();
    db.close();
  });

  const code = await new Promise<number>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout waiting for close')), 2000);
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=bad-token`);
    ws.on('close', (c) => {
      clearTimeout(timer);
      resolve(c);
    });
    ws.on('error', (e) => {
      clearTimeout(timer);
      reject(e);
    });
  });
  assert.equal(code, 4001);
});
