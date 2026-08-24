// 数据访问层：幂等 upsert + 查询。所有「合并」都走 upsert-by-id。

import type { Database } from 'better-sqlite3';
import type { Conversation, Message, User } from './types.js';

// ---- users ----

export function getUserById(db: Database, id: string): User | null {
  const row = db.prepare('SELECT * FROM users WHERE id = ?').get(id) as
    | User
    | undefined;
  return row ?? null;
}

export function getUserByUsername(db: Database, username: string): User | null {
  const row = db.prepare('SELECT * FROM users WHERE username = ?').get(username) as
    | User
    | undefined;
  return row ?? null;
}

export function createUser(
  db: Database,
  id: string,
  username: string,
  passwordHash: string,
  createdAt: number,
): void {
  db.prepare(
    'INSERT INTO users (id, username, password_hash, created_at) VALUES (?, ?, ?, ?)',
  ).run(id, username, passwordHash, createdAt);
}

// ---- conversations ----

export function upsertConversation(db: Database, c: Conversation): void {
  db.prepare(
    `INSERT INTO conversations (id, type, name, participants, created_at)
     VALUES (@id, @type, @name, @participants, @created_at)
     ON CONFLICT(id) DO UPDATE SET
       type = excluded.type,
       name = excluded.name,
       participants = excluded.participants,
       created_at = excluded.created_at`,
  ).run({
    id: c.id,
    type: c.type,
    name: c.name,
    participants: JSON.stringify(c.participants),
    created_at: c.created_at,
  });
}

export function getConversation(db: Database, id: string): Conversation | null {
  const row = db.prepare('SELECT * FROM conversations WHERE id = ?').get(id) as
    | (Omit<Conversation, 'participants'> & { participants: string })
    | undefined;
  if (!row) return null;
  return { ...row, participants: JSON.parse(row.participants) as string[] };
}

export function listConversations(db: Database): Conversation[] {
  const rows = db.prepare('SELECT * FROM conversations').all() as Array<
    Omit<Conversation, 'participants'> & { participants: string }
  >;
  return rows.map((r) => ({ ...r, participants: JSON.parse(r.participants) }));
}

/** 当前用户参与的会话（「按登录用户区分显示」的核心过滤，按用户名匹配）。 */
export function listConversationsForUser(db: Database, username: string): Conversation[] {
  return listConversations(db).filter((c) => c.participants.includes(username));
}

// ---- messages ----

export function upsertMessage(db: Database, m: Message): void {
  db.prepare(
    `INSERT INTO messages
       (id, conversation_id, sender_id, type, content, created_at, edited_at, metadata)
     VALUES (@id, @conversation_id, @sender_id, @type, @content, @created_at, @edited_at, @metadata)
     ON CONFLICT(id) DO UPDATE SET
       conversation_id = excluded.conversation_id,
       sender_id = excluded.sender_id,
       type = excluded.type,
       content = excluded.content,
       created_at = excluded.created_at,
       edited_at = excluded.edited_at,
       metadata = excluded.metadata`,
  ).run({
    id: m.id,
    conversation_id: m.conversation_id,
    sender_id: m.sender_id,
    type: m.type,
    content: m.content,
    created_at: m.created_at,
    edited_at: m.edited_at,
    metadata: JSON.stringify(m.metadata),
  });
}

export function getMessage(db: Database, id: string): Message | null {
  const row = db.prepare('SELECT * FROM messages WHERE id = ?').get(id) as
    | MessageRow
    | undefined;
  return row ? rowToMessage(row) : null;
}

/** 按会话 + 游标增量拉取：只返回 created_at 严格大于 after 的消息。 */
export function listMessages(
  db: Database,
  conversationId: string,
  after = 0,
): Message[] {
  const rows = db
    .prepare(
      'SELECT * FROM messages WHERE conversation_id = ? AND created_at > ? ORDER BY created_at ASC, id ASC',
    )
    .all(conversationId, after) as MessageRow[];
  return rows.map(rowToMessage);
}

export function listMessagesForConversation(db: Database, conversationId: string): Message[] {
  const rows = db
    .prepare(
      'SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at ASC, id ASC',
    )
    .all(conversationId) as MessageRow[];
  return rows.map(rowToMessage);
}

export function countMessages(db: Database): number {
  const row = db.prepare('SELECT COUNT(*) AS n FROM messages').get() as { n: number };
  return row.n;
}

// ---- internal row mapping ----

type MessageRow = Omit<Message, 'metadata'> & { metadata: string | null };

function rowToMessage(row: MessageRow): Message {
  return {
    ...row,
    metadata:
      row.metadata == null ? {} : (JSON.parse(row.metadata) as Record<string, unknown>),
  };
}
