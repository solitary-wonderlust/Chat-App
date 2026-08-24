// WebSocket 实时通道：认证 + 收客户端消息 + 服务端推送（经 hub.ts 广播）。

import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { Database } from 'better-sqlite3';
import type { WebSocket } from 'ws';
import { verifyToken } from './auth.js';
import { register, unregister } from './hub.js';
import { getConversation } from './store.js';
import { saveMessage, saveConversation } from './service.js';
import type { MessageType } from './types.js';

const MESSAGE_TYPES: MessageType[] = ['text', 'image', 'file', 'system'];

export function registerWs(app: FastifyInstance, db: Database): void {
  app.get('/ws', { websocket: true }, (socket: WebSocket, req: FastifyRequest) => {
    const query = req.query as { token?: string };
    const username = query.token ? verifyToken(query.token) : null;
    if (!username) {
      socket.close(4001, 'unauthorized');
      return;
    }
    register(username, socket);
    socket.on('message', (raw) => {
      handleClientMessage(db, username, raw.toString());
    });
    socket.on('close', () => unregister(username, socket));
    socket.on('error', () => unregister(username, socket));
  });
}

interface ClientEvent {
  event?: string;
  conversationId?: string;
  type?: string;
  content?: string;
  id?: string;
  createdAt?: number;
  participants?: string[];
  name?: string | null;
}

function handleClientMessage(db: Database, username: string, raw: string): void {
  let msg: ClientEvent;
  try {
    msg = JSON.parse(raw) as ClientEvent;
  } catch {
    return;
  }
  switch (msg.event) {
    case 'send_message': {
      const conversationId = msg.conversationId ?? '';
      const conv = getConversation(db, conversationId);
      if (!conv || !conv.participants.includes(username)) return;
      saveMessage(db, {
        id: msg.id,
        senderId: username,
        conversationId,
        type: MESSAGE_TYPES.includes(msg.type as MessageType)
          ? (msg.type as MessageType)
          : 'text',
        content: String(msg.content ?? ''),
        createdAt: msg.createdAt,
      });
      break;
    }
    case 'create_conversation': {
      const participants = Array.from(
        new Set([username, ...(Array.isArray(msg.participants) ? msg.participants : [])]),
      );
      if (participants.length < 2) return;
      saveConversation(db, {
        id: msg.id,
        participants,
        type: msg.type === 'group' ? 'group' : 'direct',
        name: msg.name ?? null,
      });
      break;
    }
    default:
      break;
  }
}
