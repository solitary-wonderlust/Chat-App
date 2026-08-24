// 共享数据类型：DB 行与 JSONL 记录。
// 两端（服务器 / Flutter 客户端）需保持一致，字段语义见 docs/format.md。

export type MessageType = 'text' | 'image' | 'file' | 'system';
export type ConversationType = 'direct' | 'group';

export interface User {
  id: string;
  username: string;
  password_hash: string;
  created_at: number;
}

export interface Conversation {
  id: string;
  type: ConversationType;
  name: string | null;
  participants: string[];
  created_at: number;
}

export interface Message {
  id: string;
  conversation_id: string;
  sender_id: string;
  type: MessageType;
  content: string;
  created_at: number;
  edited_at: number | null;
  metadata: Record<string, unknown>;
}

// ---- JSONL 记录（导出格式，字段为驼峰） ----

export interface ConversationRecord {
  record: 'conversation';
  id: string;
  type: ConversationType;
  name: string | null;
  participants: string[];
  createdAt: number;
}

export interface MessageRecord {
  record: 'message';
  id: string;
  conversationId: string;
  senderId: string;
  type: MessageType;
  content: string;
  createdAt: number;
  editedAt: number | null;
  metadata: Record<string, unknown>;
}

export type JsonlRecord = ConversationRecord | MessageRecord;
