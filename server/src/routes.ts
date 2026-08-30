// REST 路由：认证、会话、消息、导入导出。

import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { Database } from 'better-sqlite3';
import { randomUUID } from 'node:crypto';
import { verifyToken, hashPassword, verifyPassword, signToken } from './auth.js';
import {
  getUserByUsername,
  createUser,
  listConversationsForUser,
  getConversation,
  listMessages,
} from './store.js';
import { saveMessage, saveConversation } from './service.js';
import { exportJsonl, importJsonl } from './export.js';
import { messageToRecord, conversationToRecord } from './format.js';
import type { MessageType } from './types.js';

const MESSAGE_TYPES: MessageType[] = ['text', 'image', 'file', 'system'];

function getUsername(request: FastifyRequest): string | null {
  const header = request.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) return null;
  return verifyToken(header.slice(7));
}

export function registerRoutes(app: FastifyInstance, db: Database): void {
  app.get('/health', async () => ({ ok: true }));

  // ---- 认证 ----

  app.post('/auth/register', async (request, reply) => {
    const body = request.body as { username?: string; password?: string };
    const username = (body.username ?? '').trim();
    const password = body.password ?? '';
    if (!username || !password) {
      return reply.code(400).send({ error: 'username and password required' });
    }
    if (getUserByUsername(db, username)) {
      return reply.code(409).send({ error: 'username already taken' });
    }
    const id = randomUUID();
    createUser(db, id, username, hashPassword(password), Date.now());
    return { token: signToken(username), userId: id, username };
  });

  app.post('/auth/login', async (request, reply) => {
    const body = request.body as { username?: string; password?: string };
    const username = (body.username ?? '').trim();
    const password = body.password ?? '';
    const user = getUserByUsername(db, username);
    if (!user || !verifyPassword(password, user.password_hash)) {
      return reply.code(401).send({ error: 'invalid credentials' });
    }
    return { token: signToken(user.username), userId: user.id, username: user.username };
  });

  // ---- 会话 ----

  app.get('/conversations', async (request, reply) => {
    const username = getUsername(request);
    if (!username) return reply.code(401).send({ error: 'unauthorized' });
    return listConversationsForUser(db, username).map(conversationToRecord);
  });

  app.post('/conversations', async (request, reply) => {
    const username = getUsername(request);
    if (!username) return reply.code(401).send({ error: 'unauthorized' });
    const body = request.body as {
      participants?: string[];
      type?: string;
      name?: string | null;
      id?: string;
    };
    const participants = Array.from(
      new Set([username, ...(Array.isArray(body.participants) ? body.participants : [])]),
    );
    if (participants.length < 2) {
      return reply.code(400).send({ error: 'need at least 2 participants' });
    }
    const conv = saveConversation(db, {
      id: body.id,
      participants,
      type: body.type === 'group' ? 'group' : 'direct',
      name: body.name ?? null,
    });
    return conversationToRecord(conv);
  });

  // ---- 消息 ----

  app.get('/messages', async (request, reply) => {
    const username = getUsername(request);
    if (!username) return reply.code(401).send({ error: 'unauthorized' });
    const query = request.query as { conversationId?: string; after?: string };
    const conversationId = query.conversationId ?? '';
    const after = Number(query.after ?? 0) || 0;
    const conv = getConversation(db, conversationId);
    if (!conv || !conv.participants.includes(username)) {
      return reply.code(403).send({ error: 'not a participant' });
    }
    return listMessages(db, conversationId, after).map(messageToRecord);
  });

  app.post('/messages', async (request, reply) => {
    const username = getUsername(request);
    if (!username) return reply.code(401).send({ error: 'unauthorized' });
    const body = request.body as {
      conversationId?: string;
      type?: string;
      content?: string;
      id?: string;
      createdAt?: number;
      metadata?: Record<string, unknown>;
    };
    const conversationId = body.conversationId ?? '';
    if (!conversationId) {
      return reply.code(400).send({ error: 'conversationId required' });
    }
    const conv = getConversation(db, conversationId);
    if (!conv || !conv.participants.includes(username)) {
      return reply.code(403).send({ error: 'not a participant' });
    }
    const msg = saveMessage(db, {
      id: body.id,
      senderId: username,
      conversationId,
      type: MESSAGE_TYPES.includes(body.type as MessageType)
        ? (body.type as MessageType)
        : 'text',
      content: String(body.content ?? ''),
      createdAt: body.createdAt,
      metadata: body.metadata,
    });
    return messageToRecord(msg);
  });

  // ---- 导入 / 导出 ----

  app.get('/export', async (request, reply) => {
    const username = getUsername(request);
    if (!username) return reply.code(401).send({ error: 'unauthorized' });
    const query = request.query as { conversationId?: string };
    if (query.conversationId) {
      const conv = getConversation(db, query.conversationId);
      if (!conv || !conv.participants.includes(username)) {
        return reply.code(403).send({ error: 'not a participant' });
      }
    }
    const jsonl = exportJsonl(db, { conversationId: query.conversationId, username });
    return reply.type('application/x-ndjson').send(jsonl);
  });

  app.post('/import', async (request, reply) => {
    const username = getUsername(request);
    if (!username) return reply.code(401).send({ error: 'unauthorized' });
    const body = request.body as { text?: string };
    if (typeof body.text !== 'string' || !body.text.trim()) {
      return reply.code(400).send({ error: 'text required' });
    }
    try {
      const result = importJsonl(db, body.text);
      return result;
    } catch (e) {
      return reply.code(400).send({ error: (e as Error).message });
    }
  });
}
