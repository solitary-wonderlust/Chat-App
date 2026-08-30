// SQLite 连接与建表。本地与服务器使用完全相同的表结构（见 docs/format.md）。

import Database from 'better-sqlite3';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS users (
  id            TEXT PRIMARY KEY,
  username      TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  created_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS conversations (
  id           TEXT PRIMARY KEY,
  type         TEXT NOT NULL,
  name         TEXT,
  participants TEXT NOT NULL,
  created_at   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  sender_id       TEXT NOT NULL,
  type            TEXT NOT NULL,
  content         TEXT NOT NULL,
  created_at      INTEGER NOT NULL,
  edited_at       INTEGER,
  metadata        TEXT
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation
  ON messages(conversation_id, created_at);

-- 已读回执：每位用户在每会话的已读游标（记录层不导出，见 docs/format.md §2）。
CREATE TABLE IF NOT EXISTS read_receipts (
  conversation_id TEXT NOT NULL,
  username        TEXT NOT NULL,
  up_to           INTEGER NOT NULL,
  PRIMARY KEY (conversation_id, username)
);
`;

export function openDb(path: string = ':memory:'): Database.Database {
  const db = new Database(path);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.exec(SCHEMA);
  return db;
}
