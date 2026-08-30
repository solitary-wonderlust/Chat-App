// 阶段 4B 端到端联调：真实监听端口 + HTTP fetch + WebSocket，
// 模拟 alice / bob 两台设备走完整链路（不含单测里常用的 app.inject）。
//
// 覆盖：
//  1. 双端实时全流程 —— 建会话、发消息、WS 实时广播、编辑/撤回广播、已读回执、附件跨端鉴权；
//  2. 导出→导入到服务器→再同步 —— 跨设备合并，重复导入无重复；
//  3. 千条导入性能 —— < 1s 完成且无重复。

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import type { FastifyInstance } from 'fastify';
import { openDb } from '../../src/db.js';
import { buildApp } from '../../src/app.js';

let server: FastifyInstance;
let base: string;

before(async () => {
  server = await buildApp(openDb());
  await server.listen({ port: 0, host: '127.0.0.1' });
  const addr = server.server.address();
  const port = typeof addr === 'object' && addr ? addr.port : 0;
  base = `http://127.0.0.1:${port}`;
});

after(async () => {
  await server.close();
});

interface Auth {
  token: string;
  username: string;
}

async function register(username: string): Promise<Auth> {
  const res = await fetch(`${base}/auth/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ username, password: 'pw123456' }),
  });
  assert.equal(res.status, 200, `register ${username}`);
  const body = (await res.json()) as { token: string };
  return { token: body.token, username };
}

const authHeader = (token: string, json = false) => ({
  authorization: `Bearer ${token}`,
  ...(json ? { 'content-type': 'application/json' } : {}),
});

async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(`${base}${path}`, init);
  if (res.status >= 400) {
    throw new Error(`${init.method ?? 'GET'} ${path} -> ${res.status}: ${await res.text()}`);
  }
  const text = await res.text();
  return (text ? JSON.parse(text) : undefined) as T;
}

/** 简易 WS 客户端：事件入队，waitFor 消费队首匹配项。 */
function openWs(token: string) {
  const ws = new WebSocket(base.replace('http', 'ws') + `/ws?token=${token}`);
  const events: Array<{ event: string; data: unknown }> = [];
  const opened = new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = () => reject(new Error('ws connect failed'));
  });
  ws.onmessage = (ev) => {
    try {
      const parsed = JSON.parse(ev.data as string) as { event: string; data: unknown };
      events.push(parsed);
    } catch {
      // 忽略无法解析的帧
    }
  };
  return {
    opened,
    send(data: unknown) {
      ws.send(JSON.stringify(data));
    },
    close() {
      ws.close();
    },
    async waitFor(event: string, timeoutMs = 3000): Promise<unknown> {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        const idx = events.findIndex((e) => e.event === event);
        if (idx >= 0) return events.splice(idx, 1)[0].data;
        await new Promise((r) => setTimeout(r, 10));
      }
      throw new Error(`timeout waiting for ${event}; got ${JSON.stringify(events)}`);
    },
  };
}

test('双端实时全流程：广播、编辑、撤回、已读、附件鉴权', async () => {
  const alice = await register('e2e-alice');
  const bob = await register('e2e-bob');
  const carol = await register('e2e-carol');

  const aWs = openWs(alice.token);
  const bWs = openWs(bob.token);
  await Promise.all([aWs.opened, bWs.opened]);
  try {
    const conv = await api<{ id: string }>('/conversations', {
      method: 'POST',
      headers: authHeader(alice.token, true),
      body: JSON.stringify({ participants: [bob.username], type: 'direct' }),
    });

    // alice 发消息 → bob 的 WS 实时收到
    await api('/messages', {
      method: 'POST',
      headers: authHeader(alice.token, true),
      body: JSON.stringify({ conversationId: conv.id, type: 'text', content: '你好 bob', id: 'm1', createdAt: 1000 }),
    });
    const recv = (await bWs.waitFor('message')) as { id: string };
    assert.equal(recv.id, 'm1');

    // alice 编辑 → bob 收到 updatedAt 版本
    await api('/messages/m1', {
      method: 'PATCH',
      headers: authHeader(alice.token, true),
      body: JSON.stringify({ content: '编辑后的内容' }),
    });
    const edited = (await bWs.waitFor('message')) as { content: string; editedAt: number | null };
    assert.equal(edited.content, '编辑后的内容');
    assert.ok(edited.editedAt != null, 'editedAt 应非空');

    // alice 撤回 → bob 收到墓碑
    await api('/messages/m1', { method: 'DELETE', headers: authHeader(alice.token) });
    const tombstone = (await bWs.waitFor('message')) as { metadata: { deleted?: boolean } };
    assert.equal(tombstone.metadata?.deleted, true);

    // bob 上报已读 → alice 收到 read 事件
    await api(`/conversations/${conv.id}/read`, {
      method: 'POST',
      headers: authHeader(bob.token, true),
      body: JSON.stringify({ upTo: 5000 }),
    });
    const readEvt = (await aWs.waitFor('read')) as { username: string };
    assert.equal(readEvt.username, bob.username);

    // 附件：alice 上传，bob 可下载，carol 403（非参与者）
    const up = await api<{ url: string }>('/attachments', {
      method: 'POST',
      headers: {
        ...authHeader(alice.token),
        'content-type': 'image/png',
        'x-filename': encodeURIComponent('a.png'),
      },
      body: new Uint8Array([1, 2, 3]),
    });
    assert.equal(up.url.startsWith('/attachments/'), true);
    // 附件以 content=URL 的消息形式落库，下载鉴权依赖该消息归属
    await api('/messages', {
      method: 'POST',
      headers: authHeader(alice.token, true),
      body: JSON.stringify({ conversationId: conv.id, type: 'image', content: up.url, id: 'img1' }),
    });
    const ok = await fetch(`${base}${up.url}`, { headers: authHeader(bob.token) });
    assert.equal(ok.status, 200);
    const denied = await fetch(`${base}${up.url}`, { headers: authHeader(carol.token) });
    assert.equal(denied.status, 403);
  } finally {
    aWs.close();
    bWs.close();
  }
});

test('导出→导入到服务器→再同步，跨设备合并无重复', async () => {
  const alice = await register('e2e-a2');
  const bob = await register('e2e-b2');
  const conv = await api<{ id: string }>('/conversations', {
    method: 'POST',
    headers: authHeader(alice.token, true),
    body: JSON.stringify({ participants: [bob.username], type: 'direct' }),
  });
  for (let i = 0; i < 3; i++) {
    await api('/messages', {
      method: 'POST',
      headers: authHeader(alice.token, true),
      body: JSON.stringify({ conversationId: conv.id, type: 'text', content: `m${i}` }),
    });
  }

  // device A（alice）导出
  const exportRes = await fetch(`${base}/export`, { headers: authHeader(alice.token) });
  assert.equal(exportRes.status, 200);
  const jsonl = await exportRes.text();
  assert.match(jsonl, /"record":"message"/);

  // device B（bob）导入到服务器
  const imp = await fetch(`${base}/import`, {
    method: 'POST',
    headers: authHeader(bob.token, true),
    body: JSON.stringify({ text: jsonl }),
  });
  assert.equal(imp.status, 200);

  // alice 再同步：增量游标已越过 3 条，无新增；全量仍为 3 条
  const msgs = await api<unknown[]>('/messages?conversationId=' + conv.id, {
    headers: authHeader(alice.token),
  });
  assert.equal(msgs.length, 3);

  // 重复导入幂等：再导一次不产生副本
  await api('/import', {
    method: 'POST',
    headers: authHeader(bob.token, true),
    body: JSON.stringify({ text: jsonl }),
  });
  const msgs2 = await api<unknown[]>('/messages?conversationId=' + conv.id, {
    headers: authHeader(alice.token),
  });
  assert.equal(msgs2.length, 3);
});

test('千条导入 < 秒级且无重复', async () => {
  const alice = await register('e2e-perf');
  const conv = await api<{ id: string }>('/conversations', {
    method: 'POST',
    headers: authHeader(alice.token, true),
    body: JSON.stringify({ participants: ['bob'], type: 'direct' }),
  });

  const lines = [
    JSON.stringify({
      record: 'conversation',
      id: conv.id,
      type: 'direct',
      name: null,
      participants: [alice.username, 'bob'],
      createdAt: 1,
    }),
  ];
  for (let i = 0; i < 1000; i++) {
    lines.push(
      JSON.stringify({
        record: 'message',
        id: `perf-${i}`,
        conversationId: conv.id,
        senderId: 'alice',
        type: 'text',
        content: `msg ${i}`,
        createdAt: 1000 + i,
        editedAt: null,
        metadata: {},
      }),
    );
  }
  const text = lines.join('\n') + '\n';

  const t0 = performance.now();
  const res = await fetch(`${base}/import`, {
    method: 'POST',
    headers: authHeader(alice.token, true),
    body: JSON.stringify({ text }),
  });
  const elapsed = performance.now() - t0;
  assert.equal(res.status, 200);
  assert.ok(elapsed < 1000, `千条导入耗时 ${elapsed.toFixed(0)}ms，要求 < 1000ms`);

  // 重复导入无重复
  await api('/import', {
    method: 'POST',
    headers: authHeader(alice.token, true),
    body: JSON.stringify({ text }),
  });
  const msgs = await api<unknown[]>('/messages?conversationId=' + conv.id, {
    headers: authHeader(alice.token),
  });
  assert.equal(msgs.length, 1000);
});
