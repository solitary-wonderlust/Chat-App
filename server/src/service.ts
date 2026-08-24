// 业务服务：新建记录 + 幂等 upsert + 广播给会话成员。REST 与 WebSocket 共用。

import { randomUUID } from 'node:crypto';
import type { Database } from 'better-sqlite3';
import type { Conversation, ConversationType, Message, MessageType } from './types.js';
import { upsertConversation, upsertMessage, getConversation } from './store.js';
import { conversationToRecord, messageToRecord } from './format.js';
import { sendToUsers } from './hub.js';

export interface NewMessageInput {
  senderId: string;
  conversationId: string;
  type: MessageType;
  content: string;
  id?: string;
  createdAt?: number;
  metadata?: Record<string, unknown>;
}

export interface NewConversationInput {
  participants: string[];
  type: ConversationType;
  name?: string | null;
  id?: string;
}

/** 新建（或按 id 幂等覆盖）一条消息并广播给会话成员。 */
export function saveMessage(db: Database, input: NewMessageInput): Message {
  const msg: Message = {
    id: input.id ?? randomUUID(),
    conversation_id: input.conversationId,
    sender_id: input.senderId,
    type: input.type,
    content: input.content,
    created_at: input.createdAt ?? Date.now(),
    edited_at: null,
    metadata: input.metadata ?? {},
  };
  upsertMessage(db, msg);
  const conv = getConversation(db, msg.conversation_id);
  if (conv) {
    sendToUsers(conv.participants, { event: 'message', data: messageToRecord(msg) });
  }
  return msg;
}

/** 新建（或按 id 幂等覆盖）一个会话并广播给参与者。 */
export function saveConversation(db: Database, input: NewConversationInput): Conversation {
  const conv: Conversation = {
    id: input.id ?? randomUUID(),
    type: input.type,
    name: input.name ?? null,
    participants: input.participants,
    created_at: Date.now(),
  };
  upsertConversation(db, conv);
  sendToUsers(conv.participants, { event: 'conversation', data: conversationToRecord(conv) });
  return conv;
}
