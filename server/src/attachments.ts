// 附件：上传（原始字节）+ 鉴权下载。零外部依赖（无 @fastify/multipart、@fastify/static）。
// 上传：POST /attachments，body 为文件原始字节，头带 content-type（mime）与 x-filename（URL 编码）。
// 下载：GET /attachments/:id/:name，需登录且为该附件所在会话的参与者。
// 文件落在 <db 目录>/attachments/<fileId>/<filename>，随 SQLite 一起由 docker 数据卷持久化。

import { createReadStream, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import type { Database } from 'better-sqlite3';
import { getUsername } from './routes.js';
import { getMessageByContent, getConversation } from './store.js';

const MAX_BYTES = 25 * 1024 * 1024; // 25 MB 上限

/** 附件目录：与 SQLite 同目录下的 attachments/，随 DB_PATH 走。 */
function attachmentsDir(): string {
  const dbPath = process.env.DB_PATH ?? './data/chat.db';
  return join(dirname(resolve(dbPath)), 'attachments');
}

/**
 * 清洗文件名：去掉路径分隔符与 URL 有碍字符，禁止路径穿越。
 * 控制字符（码点 < 0x20 与 DEL 0x7f）一律剔除，保留中文等可见字符；`. ..` 兜底为 `file`。
 */
export function sanitizeFilename(name: string): string {
  const cleaned = name
    .replace(/[\\/]/g, '_')
    .replace(/[#?]/g, '_')
    .split('')
    .filter((ch) => {
      const code = ch.codePointAt(0) ?? 0;
      return code >= 0x20 && code !== 0x7f;
    })
    .join('');
  const trimmed = cleaned.trim();
  if (!trimmed || trimmed === '.' || trimmed === '..') return 'file';
  return trimmed.slice(0, 200);
}

export function registerAttachments(app: FastifyInstance, db: Database): void {
  // 原始字节 body：非 JSON/文本的 content-type 统一按 Buffer 收下；JSON 走已有解析器，不受影响。
  app.addContentTypeParser('*', (_req, payload, done) => {
    const chunks: Buffer[] = [];
    payload.on('data', (c: Buffer) => chunks.push(c));
    payload.on('end', () => done(null, Buffer.concat(chunks)));
    payload.on('error', (e: Error) => done(e));
  });

  app.post('/attachments', { bodyLimit: MAX_BYTES }, async (request, reply) => {
    const username = getUsername(request);
    if (!username) return reply.code(401).send({ error: 'unauthorized' });

    const buf = request.body as Buffer;
    if (!Buffer.isBuffer(buf) || buf.length === 0) {
      return reply.code(400).send({ error: 'empty body' });
    }
    if (buf.length > MAX_BYTES) {
      return reply.code(413).send({ error: 'file too large' });
    }

    const mime = String(request.headers['content-type'] ?? 'application/octet-stream')
      .split(';')[0]
      .trim();
    const rawName = String(request.headers['x-filename'] ?? 'file');
    const filename = sanitizeFilename(decodeURIComponent(rawName));

    const fileId = randomUUID();
    const dir = join(attachmentsDir(), fileId);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, filename), buf);

    const url = `/attachments/${fileId}/${filename}`;
    return reply.code(201).send({ url, name: filename, size: buf.length, mime });
  });

  app.get('/attachments/:id/:name', async (request, reply) => {
    const username = getUsername(request);
    if (!username) return reply.code(401).send({ error: 'unauthorized' });

    const { id, name } = request.params as { id: string; name: string };
    const url = `/attachments/${id}/${name}`;

    // 鉴权：找到引用该附件的消息，仅其会话参与者可下载。
    const msg = getMessageByContent(db, url);
    if (!msg) return reply.code(404).send({ error: 'not found' });
    const conv = getConversation(db, msg.conversation_id);
    if (!conv || !conv.participants.includes(username)) {
      return reply.code(403).send({ error: 'not a participant' });
    }

    const filePath = join(attachmentsDir(), id, name);
    if (!existsSync(filePath)) return reply.code(404).send({ error: 'not found' });

    const meta = (msg.metadata ?? {}) as Record<string, unknown>;
    reply.type(typeof meta.mime === 'string' ? meta.mime : 'application/octet-stream');
    return reply.send(createReadStream(filePath));
  });
}
