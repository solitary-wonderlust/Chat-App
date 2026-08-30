// 并发 / 重复 upsert 幂等：同一 id 重复或并发写入，最终只有一条、无副本、无报错。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from '../src/db.js';
import { buildApp } from '../src/app.js';
import { countMessages } from '../src/store.js';

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

test('重复 POST /messages 同一 id：幂等覆盖，last-write-wins', async () => {
  const { app, db } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const conv = await createConversation(app, alice.token, 'bob');

  const id = 'fixed-message-id';
  for (const content of ['v1', 'v2', 'v3']) {
    const res = await app.inject({
      method: 'POST',
      url: '/messages',
      headers: auth(alice.token),
      payload: { id, conversationId: conv.id, type: 'text', content },
    });
    assert.equal(res.statusCode, 200);
  }

  assert.equal(countMessages(db), 1);

  const msgs = await app.inject({
    method: 'GET',
    url: `/messages?conversationId=${conv.id}`,
    headers: auth(alice.token),
  });
  const list = msgs.json() as Array<{ id: string; content: string }>;
  assert.equal(list.length, 1);
  assert.equal(list[0].id, id);
  assert.equal(list[0].content, 'v3');
});

test('并发 POST /messages 同一 id：无副本、无报错，最终只有一条', async () => {
  const { app, db } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const conv = await createConversation(app, alice.token, 'bob');

  const id = 'concurrent-message-id';
  const N = 25;
  const results = await Promise.all(
    Array.from({ length: N }, (_, i) =>
      app.inject({
        method: 'POST',
        url: '/messages',
        headers: auth(alice.token),
        payload: {
          id,
          conversationId: conv.id,
          type: 'text',
          content: `c${i}`,
          createdAt: 1000 + i,
        },
      }),
    ),
  );

  // 全部成功，无报错
  for (const r of results) assert.equal(r.statusCode, 200);

  // 表中只有一条
  assert.equal(countMessages(db), 1);

  const msgs = await app.inject({
    method: 'GET',
    url: `/messages?conversationId=${conv.id}`,
    headers: auth(alice.token),
  });
  const list = msgs.json() as Array<{ id: string; content: string }>;
  assert.equal(list.length, 1);
  assert.equal(list[0].id, id);
  // last-write-wins：内容必是并发写入之一
  assert.match(list[0].content, /^c\d+$/);
});
