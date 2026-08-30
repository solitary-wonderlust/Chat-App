// /export?conversationId= 过滤：只导出指定会话，且只含当前用户参与的会话。

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
  id?: string;
  conversationId?: string;
  content?: string;
}

function parseLines(body: string): Line[] {
  return body
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((l) => JSON.parse(l) as Line);
}

test('导出指定会话：只含该会话的 conversation 与 message', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const c1 = await createConversation(app, alice.token, 'bob');
  const c2 = await createConversation(app, alice.token, 'bob');
  await postMessage(app, alice.token, c1.id, 'm1');
  await postMessage(app, alice.token, c2.id, 'm2');

  const res = await app.inject({
    method: 'GET',
    url: `/export?conversationId=${c1.id}`,
    headers: auth(alice.token),
  });
  assert.equal(res.statusCode, 200);

  const lines = parseLines(res.body);
  const convs = lines.filter((l) => l.record === 'conversation');
  const msgs = lines.filter((l) => l.record === 'message');

  assert.equal(convs.length, 1);
  assert.equal(convs[0].id, c1.id);
  assert.equal(msgs.length, 1);
  assert.equal(msgs[0].content, 'm1');
  assert.equal(msgs[0].conversationId, c1.id);
});

test('全量导出：只含当前用户参与的会话', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const carol = await register(app, 'carol');

  // bob ↔ carol 的会话，alice 不参与
  const bc = await createConversation(app, bob.token, 'carol');
  await postMessage(app, bob.token, bc.id, 'secret');

  // alice ↔ bob 的会话
  const ab = await createConversation(app, alice.token, 'bob');
  await postMessage(app, alice.token, ab.id, 'hello');

  const res = await app.inject({
    method: 'GET',
    url: '/export',
    headers: auth(alice.token),
  });
  assert.equal(res.statusCode, 200);

  const lines = parseLines(res.body);
  const convs = lines.filter((l) => l.record === 'conversation');
  const ids = convs.map((c) => c.id).sort();

  // 只应包含 alice 参与的 ab，不包含 bob↔carol 的 bc
  assert.deepEqual(ids, [ab.id]);
});

test('按发送者过滤导出：只含该用户的消息与相关会话', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const c1 = await createConversation(app, alice.token, 'bob');
  await postMessage(app, alice.token, c1.id, 'from-alice');
  await postMessage(app, bob.token, c1.id, 'from-bob');

  const res = await app.inject({
    method: 'GET',
    url: `/export?senderId=bob`,
    headers: auth(alice.token),
  });
  assert.equal(res.statusCode, 200);

  const lines = parseLines(res.body);
  const msgs = lines.filter((l) => l.record === 'message');
  assert.equal(msgs.length, 1);
  assert.equal(msgs[0].content, 'from-bob');
  assert.equal(msgs[0].senderId, 'bob');
  // 相关会话仍导出，空会话壳不导出。
  assert.equal(lines.filter((l) => l.record === 'conversation').length, 1);
});

test('按时间范围过滤导出，且过滤结果可导入', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const c1 = await createConversation(app, alice.token, 'bob');
  await postMessage(app, alice.token, c1.id, 'old', 1_000);
  await postMessage(app, alice.token, c1.id, 'middle', 2_000);
  await postMessage(app, alice.token, c1.id, 'new', 3_000);

  // 只导出 [1500, 2500] 区间
  const res = await app.inject({
    method: 'GET',
    url: '/export?from=1500&to=2500',
    headers: auth(alice.token),
  });
  assert.equal(res.statusCode, 200);
  const lines = parseLines(res.body);
  const msgs = lines.filter((l) => l.record === 'message');
  assert.deepEqual(
    msgs.map((m) => m.content),
    ['middle'],
  );

  // 过滤结果导入空库：会话 + 1、消息 + 1，内容正确。
  const { app: app2 } = await makeApp();
  await register(app2, 'alice');
  const imp = await app2.inject({
    method: 'POST',
    url: '/import',
    headers: auth(alice.token),
    payload: { text: res.body },
  });
  assert.equal(imp.statusCode, 200);
  assert.deepEqual(imp.json(), { conversations: 1, messages: 1 });

  const exp = await app2.inject({
    method: 'GET',
    url: '/export',
    headers: auth(alice.token),
  });
  const expMsgs = parseLines(exp.body).filter((l) => l.record === 'message');
  assert.equal(expMsgs.length, 1);
  assert.equal(expMsgs[0].content, 'middle');
});
