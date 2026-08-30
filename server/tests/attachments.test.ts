// 附件集成测试：上传、鉴权下载、越权 403、导入导出往返。

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { openDb } from '../src/db.js';
import { buildApp } from '../src/app.js';

// 附件目录跟随 DB_PATH，这里指到临时目录并在结束清理。
const TEST_DIR = './data/test-attachments';
process.env.DB_PATH = `${TEST_DIR}/chat.db`;

after(() => {
  rmSync(TEST_DIR, { recursive: true, force: true });
});

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

async function makeConversation(app: ReturnType<typeof buildApp>, token: string, others: string[]) {
  const res = await app.inject({
    method: 'POST',
    url: '/conversations',
    headers: auth(token),
    payload: { participants: others },
  });
  assert.equal(res.statusCode, 200);
  return res.json() as { id: string };
}

/** 上传一个 4 字节附件，返回响应。 */
async function upload(
  app: ReturnType<typeof buildApp>,
  token: string,
  bytes: Buffer = Buffer.from([0x89, 0x50, 0x4e, 0x47]),
  name = 'pic.png',
  mime = 'image/png',
) {
  return app.inject({
    method: 'POST',
    url: '/attachments',
    headers: {
      ...auth(token),
      'content-type': mime,
      'x-filename': encodeURIComponent(name),
    },
    payload: bytes,
  });
}

test('上传返回 URL，可带鉴权下载，字节一致', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const conv = await makeConversation(app, alice.token, ['bob']);

  const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a]);
  const up = await upload(app, alice.token, bytes, '照片.png');
  assert.equal(up.statusCode, 201);
  const { url, name, size, mime } = up.json() as {
    url: string;
    name: string;
    size: number;
    mime: string;
  };
  assert.equal(name, '照片.png');
  assert.equal(size, bytes.length);
  assert.equal(mime, 'image/png');
  assert.match(url, /^\/attachments\/[0-9a-f-]{36}\/照片\.png$/);

  // 消息引用该附件（type=image）
  const msg = await app.inject({
    method: 'POST',
    url: '/messages',
    headers: auth(alice.token),
    payload: {
      conversationId: conv.id,
      type: 'image',
      content: url,
      metadata: { name, size, mime },
    },
  });
  assert.equal(msg.statusCode, 200);

  // 参与者可下载，字节与 mime 一致
  const dl = await app.inject({
    method: 'GET',
    url,
    headers: auth(alice.token),
  });
  assert.equal(dl.statusCode, 200);
  assert.equal(dl.headers['content-type'], 'image/png');
  assert.deepEqual(dl.rawPayload, bytes);

  const dlBob = await app.inject({ method: 'GET', url, headers: auth(bob.token) });
  assert.equal(dlBob.statusCode, 200);
});

test('未认证 401 / 越权 403 / 不存在 404', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const carol = await register(app, 'carol');
  const conv = await makeConversation(app, alice.token, ['bob']);

  const up = await upload(app, alice.token);
  assert.equal(up.statusCode, 201);
  const url = (up.json() as { url: string }).url;
  await app.inject({
    method: 'POST',
    url: '/messages',
    headers: auth(alice.token),
    payload: { conversationId: conv.id, type: 'image', content: url },
  });

  // 无 token → 401
  const noAuth = await app.inject({ method: 'GET', url });
  assert.equal(noAuth.statusCode, 401);

  // 非参与者 carol → 403
  const carolDl = await app.inject({ method: 'GET', url, headers: auth(carol.token) });
  assert.equal(carolDl.statusCode, 403);

  // 不存在的附件 → 404
  const missing = await app.inject({
    method: 'GET',
    url: '/attachments/00000000-0000-0000-0000-000000000000/nope.png',
    headers: auth(alice.token),
  });
  assert.equal(missing.statusCode, 404);
});

test('上传校验：未认证 401 / 空 body 400', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');

  const noAuth = await app.inject({
    method: 'POST',
    url: '/attachments',
    headers: { 'content-type': 'image/png', 'x-filename': 'a.png' },
    payload: Buffer.from([1, 2, 3]),
  });
  assert.equal(noAuth.statusCode, 401);

  const empty = await upload(app, alice.token, Buffer.alloc(0));
  assert.equal(empty.statusCode, 400);
});

test('文件名清洗：路径分隔符/控制字符被剔除，URL 无路径穿越', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');

  const up = await upload(app, alice.token, Buffer.from([1, 2, 3]), '../evil#a?b.png');
  assert.equal(up.statusCode, 201);
  const url = (up.json() as { url: string }).url;
  // 路径分隔符/控制字符/URL 有碍字符都被剔除，文件名部分不可穿越路径
  assert.match(url, /^\/attachments\/[0-9a-f-]{36}\/\.\._evil_a_b\.png$/);
});

test('附件消息在导出/导入中 content=URL 往返不变', async () => {
  const { app } = await makeApp();
  const alice = await register(app, 'alice');
  const bob = await register(app, 'bob');
  const conv = await makeConversation(app, alice.token, ['bob']);

  const up = await upload(app, alice.token);
  const url = (up.json() as { url: string }).url;
  await app.inject({
    method: 'POST',
    url: '/messages',
    headers: auth(alice.token),
    payload: { conversationId: conv.id, type: 'image', content: url },
  });

  const exportRes = await app.inject({
    method: 'GET',
    url: '/export',
    headers: auth(alice.token),
  });
  const text = exportRes.body;
  assert.match(text, /"type":"image"/);
  assert.ok(text.includes(url));

  const importRes = await app.inject({
    method: 'POST',
    url: '/import',
    headers: auth(alice.token),
    payload: { text },
  });
  assert.equal(importRes.statusCode, 200);

  const msgs = await app.inject({
    method: 'GET',
    url: `/messages?conversationId=${conv.id}`,
    headers: auth(alice.token),
  });
  const rows = msgs.json() as Array<{ type: string; content: string }>;
  const image = rows.find((r) => r.type === 'image');
  assert.ok(image);
  assert.equal(image.content, url);
});
