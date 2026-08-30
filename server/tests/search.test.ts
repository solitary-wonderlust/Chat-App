// GET /search：按关键词搜消息，只搜当前用户参与的会话。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from '../src/db.js';
import { buildApp } from '../src/app.js';

async function makeApp() {
  const db = openDb();
  return { db, app: await buildApp(db) };
}

async function register(app: ReturnType<typeof buildApp>, username: string) {
  const res = await app.inject({
    method: 'POST',
    url: '/auth/register',
    payload: { username, password: 'pw123456' },
  });
  assert.equal(res.statusCode, 200);
  return res.json() as { token: string; userId: string };
}

function auth(token: string) {
  return { authorization: `Bearer ${token}` };
}

async function createConversation(
  app: ReturnType<typeof buildApp>,
  token: string,
  withUser: string,
) {
  const res = await app.inject({
    method: 'POST',
    url: '/conversations',
    headers: auth(token),
    payload: { participants: [withUser] },
  });
  assert.equal(res.statusCode, 200);
  return res.json() as { id: string };
}

async function postMessage(
  app: ReturnType<typeof buildApp>,
  token: string,
  conversationId: string,
  content: string,
  createdAt?: number,
) {
  const res = await app.inject({
    method: 'POST',
    url: '/messages',
    headers: auth(token),
    payload: { conversationId, type: 'text', content, createdAt },
  });
  assert.equal(res.statusCode, 200);
  return res.json() as { id: string };
}

interface Line {
  record: string;
  content?: string;
  conversationId?: string;
  senderId?: string;
}

// /search 返回 JSON 数组（非 JSONL），直接解析。
function parseSearch(res: { json(): unknown }): Line[] {
  return res.json() as Line[];
}

test('按关键词搜索命中：跨会话、大小写不敏感', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const c1 = await createConversation(app, alice.token, 'bob');
  const c2 = await createConversation(app, alice.token, 'bob');
  await postMessage(app, alice.token, c1.id, 'hello world');
  await postMessage(app, alice.token, c1.id, 'goodbye');
  await postMessage(app, bob.token, c2.id, 'Hello there');

  const res = await app.inject({
    method: 'GET',
    url: '/search?q=hello',
    headers: auth(alice.token),
  });
  assert.equal(res.statusCode, 200);
  const msgs = parseSearch(res);
  // hello world + Hello there（大小写不敏感）
  assert.deepEqual(
    msgs.map((m) => m.content).sort(),
    ['Hello there', 'hello world'],
  );
});

test('按会话限定搜索 + 时间范围', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const c1 = await createConversation(app, alice.token, 'bob');
  const c2 = await createConversation(app, alice.token, 'bob');
  await postMessage(app, alice.token, c1.id, 'shared', 1_000);
  await postMessage(app, alice.token, c2.id, 'shared', 2_000);

  // 限定 c1：只命中 c1 的 shared
  const r1 = await app.inject({
    method: 'GET',
    url: `/search?q=shared&conversationId=${c1.id}`,
    headers: auth(alice.token),
  });
  assert.equal(r1.statusCode, 200);
  assert.equal(parseSearch(r1).length, 1);
  assert.equal(parseSearch(r1)[0].conversationId, c1.id);

  // 时间范围 [1500, ...]：只命中 c2
  const r2 = await app.inject({
    method: 'GET',
    url: '/search?q=shared&from=1500',
    headers: auth(alice.token),
  });
  assert.equal(r2.statusCode, 200);
  assert.equal(parseSearch(r2)[0].conversationId, c2.id);
});

test('不搜索未参与会话的消息', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const carol = await register(app, 'carol');

  // bob ↔ carol 的会话，alice 不参与
  const bc = await createConversation(app, bob.token, 'carol');
  await postMessage(app, bob.token, bc.id, 'secret-plan');

  const res = await app.inject({
    method: 'GET',
    url: '/search?q=secret-plan',
    headers: auth(alice.token),
  });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(parseSearch(res), []);
});

test('未登录 / 缺 q / 非参与者：401 / 400 / 403', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const carol = await register(app, 'carol');
  const bc = await createConversation(app, bob.token, 'carol');

  // 未登录
  const r401 = await app.inject({ method: 'GET', url: '/search?q=hi' });
  assert.equal(r401.statusCode, 401);

  // 缺 q
  const r400 = await app.inject({
    method: 'GET',
    url: '/search',
    headers: auth(alice.token),
  });
  assert.equal(r400.statusCode, 400);

  // alice 搜索 bc（非参与者）
  const r403 = await app.inject({
    method: 'GET',
    url: `/search?q=hi&conversationId=${bc.id}`,
    headers: auth(alice.token),
  });
  assert.equal(r403.statusCode, 403);
});

test('LIKE 通配符被转义：搜索 % 不匹配所有', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const c1 = await createConversation(app, alice.token, 'bob');
  await postMessage(app, alice.token, c1.id, 'progress 100%');
  await postMessage(app, alice.token, c1.id, 'ordinary');

  const res = await app.inject({
    method: 'GET',
    url: '/search?q=%25',
    headers: auth(alice.token),
  });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(
    parseSearch(res).map((m) => m.content),
    ['progress 100%'],
  );
});
