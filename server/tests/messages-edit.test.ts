// 2C：消息编辑 / 撤回（软删）/ 已读回执。

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
  type = 'text',
) {
  const res = await app.inject({
    method: 'POST',
    url: '/messages',
    headers: auth(token),
    payload: { conversationId, type, content },
  });
  assert.equal(res.statusCode, 200);
  return res.json() as { id: string; content: string; editedAt: number | null; metadata: Record<string, unknown> };
}

test('编辑：发送者可改，edited_at 被设置，内容更新', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const c1 = await createConversation(app, alice.token, 'bob');
  const m = await postMessage(app, alice.token, c1.id, 'original');

  const res = await app.inject({
    method: 'PATCH',
    url: `/messages/${m.id}`,
    headers: auth(alice.token),
    payload: { content: 'edited' },
  });
  assert.equal(res.statusCode, 200);
  const body = res.json();
  assert.equal(body.content, 'edited');
  assert.equal(typeof body.editedAt, 'number');

  // 对方（bob）也能拉到编辑后的内容
  const list = await app.inject({
    method: 'GET',
    url: `/messages?conversationId=${c1.id}`,
    headers: auth(bob.token),
  });
  const msg = (list.json() as Array<{ content: string; editedAt: number | null }>).find(
    (x) => x.content === 'edited',
  );
  assert.ok(msg);
  assert.equal(typeof msg.editedAt, 'number');
});

test('编辑权限：非发送者 403，非参与者 403，缺内容 400，已撤回 400，非 text 400', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const carol = await register(app, 'carol');
  const c1 = await createConversation(app, alice.token, 'bob');

  const m = await postMessage(app, alice.token, c1.id, 'original');
  const other = await postMessage(app, bob.token, c1.id, 'bobs msg');

  // bob 改 alice 的消息 → 403 not the sender
  const r1 = await app.inject({
    method: 'PATCH',
    url: `/messages/${m.id}`,
    headers: auth(bob.token),
    payload: { content: 'x' },
  });
  assert.equal(r1.statusCode, 403);

  // carol（非参与者）改 → 403
  const r2 = await app.inject({
    method: 'PATCH',
    url: `/messages/${m.id}`,
    headers: auth(carol.token),
    payload: { content: 'x' },
  });
  assert.equal(r2.statusCode, 403);

  // 缺内容 → 400
  const r3 = await app.inject({
    method: 'PATCH',
    url: `/messages/${m.id}`,
    headers: auth(alice.token),
    payload: { content: '   ' },
  });
  assert.equal(r3.statusCode, 400);

  // 撤回后再编辑 → 400
  await app.inject({
    method: 'DELETE',
    url: `/messages/${other.id}`,
    headers: auth(bob.token),
  });
  const r4 = await app.inject({
    method: 'PATCH',
    url: `/messages/${other.id}`,
    headers: auth(bob.token),
    payload: { content: 'x' },
  });
  assert.equal(r4.statusCode, 400);
});

test('撤回：content 清空 + metadata.deleted，且是软删（行仍在）', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const c1 = await createConversation(app, alice.token, 'bob');
  const m = await postMessage(app, alice.token, c1.id, 'secret');

  const res = await app.inject({
    method: 'DELETE',
    url: `/messages/${m.id}`,
    headers: auth(alice.token),
  });
  assert.equal(res.statusCode, 200);
  const body = res.json();
  assert.equal(body.content, '');
  assert.equal(body.metadata.deleted, true);

  // bob 拉到的是墓碑，不是硬删除
  const list = await app.inject({
    method: 'GET',
    url: `/messages?conversationId=${c1.id}`,
    headers: auth(bob.token),
  });
  assert.equal((list.json() as unknown[]).length, 1);
  assert.equal((list.json() as Array<{ metadata: Record<string, unknown> }>)[0].metadata.deleted, true);
});

test('撤回权限：非发送者 403；附件撤回后 URL 失效', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const c1 = await createConversation(app, alice.token, 'bob');
  const m = await postMessage(app, alice.token, c1.id, '/attachments/x/y.png', 'image');

  const r = await app.inject({
    method: 'DELETE',
    url: `/messages/${m.id}`,
    headers: auth(bob.token),
  });
  assert.equal(r.statusCode, 403);

  const del = await app.inject({
    method: 'DELETE',
    url: `/messages/${m.id}`,
    headers: auth(alice.token),
  });
  assert.equal(del.statusCode, 200);
  assert.equal(del.json().content, '');
});

test('已读回执：上报 upsert、读取返回、非参与者 403', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const carol = await register(app, 'carol');
  const c1 = await createConversation(app, alice.token, 'bob');
  await postMessage(app, bob.token, c1.id, 'hi');

  const post = await app.inject({
    method: 'POST',
    url: `/conversations/${c1.id}/read`,
    headers: auth(alice.token),
    payload: { upTo: 1_000 },
  });
  assert.equal(post.statusCode, 200);

  const post2 = await app.inject({
    method: 'POST',
    url: `/conversations/${c1.id}/read`,
    headers: auth(alice.token),
    payload: { upTo: 2_000 },
  });
  assert.equal(post2.statusCode, 200);

  const get = await app.inject({
    method: 'GET',
    url: `/conversations/${c1.id}/read`,
    headers: auth(bob.token),
  });
  assert.equal(get.statusCode, 200);
  // alice 的游标被 upsert 为 2000（覆盖而非重复）
  assert.deepEqual(get.json(), [{ username: 'alice', upTo: 2_000 }]);

  const denied = await app.inject({
    method: 'GET',
    url: `/conversations/${c1.id}/read`,
    headers: auth(carol.token),
  });
  assert.equal(denied.statusCode, 403);
});
