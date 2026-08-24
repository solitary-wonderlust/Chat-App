// JSONL 编解码：把 DB 行序列化为 JSONL 行、把 JSONL 行解析为记录。
// 规则见 docs/format.md。这里刻意与 Flutter 客户端的 import_export 保持一致。

import { createHash } from 'node:crypto';
import type {
  Conversation,
  Message,
  ConversationRecord,
  MessageRecord,
  JsonlRecord,
  MessageType,
} from './types.js';

const MESSAGE_TYPES: MessageType[] = ['text', 'image', 'file', 'system'];

// 确定性 id 的分隔符（NUL），避免字段内容在拼接时撞车。
const SEP = String.fromCharCode(0);

/**
 * 为没有 id 的第三方记录生成确定性 id（SHA-1 hex）。
 * 幂等：相同输入永远得到相同 id，重复导入不会产生副本。
 */
export function deterministicId(
  conversationId: string,
  senderId: string,
  content: string,
  createdAt: number,
): string {
  return createHash('sha1')
    .update([conversationId, senderId, content, String(createdAt)].join(SEP))
    .digest('hex');
}

// ---- DB 行 -> JSONL 记录 ----

export function conversationToRecord(c: Conversation): ConversationRecord {
  return {
    record: 'conversation',
    id: c.id,
    type: c.type,
    name: c.name,
    participants: c.participants,
    createdAt: c.created_at,
  };
}

export function messageToRecord(m: Message): MessageRecord {
  return {
    record: 'message',
    id: m.id,
    conversationId: m.conversation_id,
    senderId: m.sender_id,
    type: m.type,
    content: m.content,
    createdAt: m.created_at,
    editedAt: m.edited_at,
    metadata: m.metadata,
  };
}

// ---- JSONL 记录 -> DB 行 ----

export function recordToConversation(r: ConversationRecord): Conversation {
  return {
    id: r.id,
    type: r.type,
    name: r.name,
    participants: r.participants,
    created_at: r.createdAt,
  };
}

export function recordToMessage(r: MessageRecord): Message {
  return {
    id: r.id,
    conversation_id: r.conversationId,
    sender_id: r.senderId,
    type: r.type,
    content: r.content,
    created_at: r.createdAt,
    edited_at: r.editedAt,
    metadata: r.metadata,
  };
}

// ---- 序列化 / 解析 ----

export function toJsonlLine(rec: JsonlRecord): string {
  return JSON.stringify(rec);
}

/** 解析一行 JSONL；空行/纯空白返回 null；非法 JSON 抛错。 */
export function parseJsonlLine(line: string): JsonlRecord | null {
  const trimmed = line.trim();
  if (!trimmed) return null;
  const obj = JSON.parse(trimmed) as Record<string, unknown>;
  if (obj.record === 'conversation') return normalizeConversation(obj);
  if (obj.record === 'message') return normalizeMessage(obj);
  throw new Error(`unknown record type: ${String(obj.record)}`);
}

function normalizeConversation(obj: Record<string, unknown>): ConversationRecord {
  const id =
    typeof obj.id === 'string' && obj.id ? obj.id : deterministicId('', '', '', 0);
  const participants = Array.isArray(obj.participants)
    ? obj.participants.map(String)
    : [];
  return {
    record: 'conversation',
    id,
    type: obj.type === 'group' ? 'group' : 'direct',
    name: obj.name == null ? null : String(obj.name),
    participants,
    createdAt: Number(obj.createdAt ?? 0),
  };
}

function normalizeMessage(obj: Record<string, unknown>): MessageRecord {
  const conversationId = String(obj.conversationId ?? '');
  const senderId = String(obj.senderId ?? '');
  const content = String(obj.content ?? '');
  const createdAt = Number(obj.createdAt ?? 0);
  const id =
    typeof obj.id === 'string' && obj.id
      ? obj.id
      : deterministicId(conversationId, senderId, content, createdAt);
  const type = MESSAGE_TYPES.includes(obj.type as MessageType)
    ? (obj.type as MessageType)
    : 'text';
  return {
    record: 'message',
    id,
    conversationId,
    senderId,
    type,
    content,
    createdAt,
    editedAt: obj.editedAt == null ? null : Number(obj.editedAt),
    metadata:
      obj.metadata && typeof obj.metadata === 'object' && !Array.isArray(obj.metadata)
        ? (obj.metadata as Record<string, unknown>)
        : {},
  };
}

/** 将整段 JSONL 文本按行解析为记录数组（跳过空行）。 */
export function parseJsonl(text: string): JsonlRecord[] {
  const out: JsonlRecord[] = [];
  for (const line of text.split('\n')) {
    const rec = parseJsonlLine(line);
    if (rec) out.push(rec);
  }
  return out;
}
