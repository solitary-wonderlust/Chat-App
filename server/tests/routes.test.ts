// 集成测试：REST 认证、多用户隔离、导入导出接口。

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

test('注册 / 登录 / 重复用户名 409', async () => {
  const { app } = await makeApp();
  const a = await register(app, 'alice');
  assert.ok(a.token);

  const login = await app.inject({
    method: 'POST',
    url: '/auth/login',
    payload: { username: 'alice', password: 'pw123456' },
  });
  assert.equal(login.statusCode, 200);

  const dup = await app.inject({
    method: 'POST',
    url: '/auth/register',
    payload: { username: 'alice', password: 'other' },
  });
  assert.equal(dup.statusCode, 409);
});

test('多用户隔离：A 的消息 B 可见，C 不可见', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const carol = await register(app, 'carol');

  // alice 建会话（与 bob）
  const convRes = await app.inject({
    method: 'POST',
    url: '/conversations',
    headers: auth(alice.token),
    payload: { participants: ['bob'], type: 'direct' },
  });
  assert.equal(convRes.statusCode, 200);
  const conv = convRes.json() as { id: string; participants: string[] };
  assert.deepEqual(conv.participants, ['alice', 'bob']);

  // alice 发消息
  const msgRes = await app.inject({
    method: 'POST',
    url: '/messages',
    headers: auth(alice.token),
    payload: { conversationId: conv.id, type: 'text', content: 'hello bob' },
  });
  assert.equal(msgRes.statusCode, 200);

  // bob 能看到会话和消息
  const bobConvs = await app.inject({
    method: 'GET',
    url: '/conversations',
    headers: auth(bob.token),
  });
  assert.equal((bobConvs.json() as unknown[]).length, 1);

  const bobMsgs = await app.inject({
    method: 'GET',
    url: `/messages?conversationId=${conv.id}`,
    headers: auth(bob.token),
  });
  assert.equal((bobMsgs.json() as unknown[]).length, 1);

  // carol 看不到会话，也拉不到消息（403）
  const carolConvs = await app.inject({
    method: 'GET',
    url: '/conversations',
    headers: auth(carol.token),
  });
  assert.equal((carolConvs.json() as unknown[]).length, 0);

  const carolMsgs = await app.inject({
    method: 'GET',
    url: `/messages?conversationId=${conv.id}`,
    headers: auth(carol.token),
  });
  assert.equal(carolMsgs.statusCode, 403);
});

test('消息增量拉取（after 游标）', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const conv = (
    await app.inject({
      method: 'POST',
      url: '/conversations',
      headers: auth(alice.token),
      payload: { participants: ['bob'] },
    })
  ).json() as { id: string };

  for (let i = 0; i < 3; i++) {
    await app.inject({
      method: 'POST',
      url: '/messages',
      headers: auth(alice.token),
      payload: { conversationId: conv.id, type: 'text', content: `m${i}`, createdAt: 1000 + i },
    });
  }
  const page = await app.inject({
    method: 'GET',
    url: `/messages?conversationId=${conv.id}&after=1001`,
    headers: auth(alice.token),
  });
  const msgs = page.json() as Array<{ createdAt: number }>;
  assert.equal(msgs.length, 1);
  assert.equal(msgs[0].createdAt, 1002);
});

test('导出接口返回 JSONL，导入接口可回灌', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const conv = (
    await app.inject({
      method: 'POST',
      url: '/conversations',
      headers: auth(alice.token),
      payload: { participants: ['bob'] },
    })
  ).json() as { id: string };
  await app.inject({
    method: 'POST',
    url: '/messages',
    headers: auth(alice.token),
    payload: { conversationId: conv.id, type: 'text', content: 'exported' },
  });

  const exportRes = await app.inject({
    method: 'GET',
    url: '/export',
    headers: auth(alice.token),
  });
  assert.equal(exportRes.statusCode, 200);
  const text = exportRes.body;
  assert.match(text, /"record":"message"/);

  const importRes = await app.inject({
    method: 'POST',
    url: '/import',
    headers: auth(alice.token),
    payload: { text },
  });
  assert.equal(importRes.statusCode, 200);
  const result = importRes.json() as { conversations: number; messages: number };
  assert.equal(result.messages, 1);
});
