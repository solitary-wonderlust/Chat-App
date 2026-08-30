// 导入 / 导出 JSONL。两遍扫描 + upsert-by-id，保证幂等合并。
// 与 docs/format.md 第 4 节「导入规则」严格对应。

import { randomUUID } from 'node:crypto';
import type { Database } from 'better-sqlite3';
import type {
  Conversation,
  ConversationRecord,
  Message,
  MessageRecord,
} from './types.js';
import {
  parseJsonl,
  conversationToRecord,
  messageToRecord,
  recordToConversation,
  recordToMessage,
  toJsonlLine,
} from './format.js';
import {
  upsertConversation,
  upsertMessage,
  getConversation,
  listConversations,
  listMessagesForConversation,
} from './store.js';

export interface ExportOptions {
  /** 只导出指定会话；省略则导出全部。 */
  conversationId?: string;
  /** 按登录用户过滤：只导出该用户参与的会话（「按登录用户区分显示」）。 */
  username?: string;
  /** 只导出该发送者的消息。 */
  senderId?: string;
  /** 只导出 created_at >= from 的消息（epoch 毫秒）。 */
  from?: number;
  /** 只导出 created_at <= to 的消息（epoch 毫秒）。 */
  to?: number;
}

/** 生成 JSONL 文本：先写 conversation 行，再写 message 行。 */
export function exportJsonl(db: Database, opts: ExportOptions = {}): string {
  const lines: string[] = [];
  let conversations: Conversation[] = opts.conversationId
    ? [getConversation(db, opts.conversationId)].filter(
        (c): c is Conversation => c != null,
      )
    : listConversations(db);

  if (opts.username) {
    conversations = conversations.filter((c) =>
      c.participants.includes(opts.username as string),
    );
  }

  const matchesFilter = (m: Message): boolean => {
    if (opts.senderId != null && m.sender_id !== opts.senderId) return false;
    if (opts.from != null && m.created_at < opts.from) return false;
    if (opts.to != null && m.created_at > opts.to) return false;
    return true;
  };

  // 有消息级过滤时，只保留至少含一条命中消息的会话，避免导出空会话壳。
  if (opts.senderId != null || opts.from != null || opts.to != null) {
    conversations = conversations.filter((c) =>
      listMessagesForConversation(db, c.id).some(matchesFilter),
    );
  }

  for (const c of conversations) {
    lines.push(toJsonlLine(conversationToRecord(c)));
  }
  for (const c of conversations) {
    for (const m of listMessagesForConversation(db, c.id)) {
      if (matchesFilter(m)) lines.push(toJsonlLine(messageToRecord(m)));
    }
  }
  return lines.join('\n') + (lines.length ? '\n' : '');
}

export interface ImportResult {
  conversations: number;
  messages: number;
}

/** 导入 JSONL 文本：两遍扫描，conversation 先于 message。 */
export function importJsonl(db: Database, text: string): ImportResult {
  const records = parseJsonl(text);
  const conversations: ConversationRecord[] = [];
  const messages: MessageRecord[] = [];
  for (const r of records) {
    if (r.record === 'conversation') conversations.push(r);
    else messages.push(r);
  }

  const tx = db.transaction(() => {
    for (const r of conversations) {
      upsertConversation(db, recordToConversation(r));
    }
    for (const r of messages) {
      // 悬空引用：文件里没有、库里也没有 → 惰性建占位 direct 会话。
      if (!getConversation(db, r.conversationId)) {
        upsertConversation(db, {
          id: r.conversationId,
          type: 'direct',
          name: null,
          participants: [r.senderId],
          created_at: r.createdAt,
        });
      }
      upsertMessage(db, recordToMessage(r));
    }
  });
  tx();

  return { conversations: conversations.length, messages: messages.length };
}

/** 生成一个全新 UUID，供新建记录使用（客户端/服务端同款逻辑）。 */
export function newId(): string {
  return randomUUID();
}
