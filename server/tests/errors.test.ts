// 错误路径集成测试：401 / 403 / 409 / 400。

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

async function createConversation(app: ReturnType<typeof buildApp>, token: string, withUser: string) {
  const res = await app.inject({
    method: 'POST',
    url: '/conversations',
    headers: auth(token),
    payload: { participants: [withUser] },
  });
  assert.equal(res.statusCode, 200);
  return res.json() as { id: string };
}

test('401：无 token / 坏 token / 非 Bearer 前缀', async () => {
  const { app } = await makeApp();

  for (const url of ['/conversations', '/messages?conversationId=x', '/export']) {
    const res = await app.inject({ method: 'GET', url });
    assert.equal(res.statusCode, 401, `GET ${url} 无 token 应 401`);
  }

  const bad = await app.inject({
    method: 'GET',
    url: '/conversations',
    headers: { authorization: 'Bearer not-a-valid-jwt' },
  });
  assert.equal(bad.statusCode, 401);

  const noBearer = await app.inject({
    method: 'GET',
    url: '/conversations',
    headers: { authorization: 'Token abc' },
  });
  assert.equal(noBearer.statusCode, 401);
});

test('403：非参与者访问 /messages（GET 与 POST）', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const carol = await register(app, 'carol');
  const conv = await createConversation(app, alice.token, 'bob');

  const getRes = await app.inject({
    method: 'GET',
    url: `/messages?conversationId=${conv.id}`,
    headers: auth(carol.token),
  });
  assert.equal(getRes.statusCode, 403);

  const postRes = await app.inject({
    method: 'POST',
    url: '/messages',
    headers: auth(carol.token),
    payload: { conversationId: conv.id, type: 'text', content: 'x' },
  });
  assert.equal(postRes.statusCode, 403);
});

test('403：非参与者导出指定会话', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const carol = await register(app, 'carol');
  const conv = await createConversation(app, alice.token, 'bob');

  const res = await app.inject({
    method: 'GET',
    url: `/export?conversationId=${conv.id}`,
    headers: auth(carol.token),
  });
  assert.equal(res.statusCode, 403);
});

test('409：重复注册用户名', async () => {
  const { app } = await makeApp();
  await register(app, 'alice');

  const dup = await app.inject({
    method: 'POST',
    url: '/auth/register',
    payload: { username: 'alice', password: 'other-pass' },
  });
  assert.equal(dup.statusCode, 409);
});

test('400：缺参数', async () => {
  const { app } = await makeApp();

  // 注册缺 password / username
  const noPw = await app.inject({
    method: 'POST',
    url: '/auth/register',
    payload: { username: 'alice' },
  });
  assert.equal(noPw.statusCode, 400);

  const noName = await app.inject({
    method: 'POST',
    url: '/auth/register',
    payload: { password: 'x' },
  });
  assert.equal(noName.statusCode, 400);

  // 已注册用户：POST /messages 缺 conversationId
  const alice = await register(app, 'alice2');
  const noConv = await app.inject({
    method: 'POST',
    url: '/messages',
    headers: auth(alice.token),
    payload: { type: 'text', content: 'x' },
  });
  assert.equal(noConv.statusCode, 400);

  // POST /conversations 参与者不足
  const fewParts = await app.inject({
    method: 'POST',
    url: '/conversations',
    headers: auth(alice.token),
    payload: { participants: [] },
  });
  assert.equal(fewParts.statusCode, 400);

  // POST /import 缺 text
  const noText = await app.inject({
    method: 'POST',
    url: '/import',
    headers: auth(alice.token),
    payload: {},
  });
  assert.equal(noText.statusCode, 400);
});
