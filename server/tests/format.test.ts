// 单元测试：幂等 upsert、JSONL 往返、合并去重、无 UUID 的确定性 id。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from '../src/db.js';
import {
  upsertMessage,
  upsertConversation,
  countMessages,
  listConversationsForUser,
  listMessagesForConversation,
  getConversation,
} from '../src/store.js';
import { exportJsonl, importJsonl } from '../src/export.js';
import { deterministicId } from '../src/format.js';
import type { Conversation, Message } from '../src/types.js';

function makeConversation(over: Partial<Conversation> = {}): Conversation {
  return {
    id: 'c1',
    type: 'direct',
    name: null,
    participants: ['alice', 'bob'],
    created_at: 0,
    ...over,
  };
}

function makeMessage(over: Partial<Message> = {}): Message {
  return {
    id: 'm1',
    conversation_id: 'c1',
    sender_id: 'alice',
    type: 'text',
    content: 'hi',
    created_at: 1000,
    edited_at: null,
    metadata: {},
    ...over,
  };
}

test('upsert by id 幂等：重复写入不产生副本，且被覆盖', () => {
  const db = openDb();
  upsertMessage(db, makeMessage());
  upsertMessage(db, makeMessage({ content: 'changed' }));
  assert.equal(countMessages(db), 1);
  assert.equal(listMessagesForConversation(db, 'c1')[0].content, 'changed');
});

test('listConversationsForUser 按参与者过滤', () => {
  const db = openDb();
  upsertConversation(db, makeConversation({ id: 'c1', participants: ['alice', 'bob'] }));
  upsertConversation(db, makeConversation({ id: 'c2', participants: ['alice', 'carol'] }));
  assert.deepEqual(
    listConversationsForUser(db, 'alice').map((c) => c.id).sort(),
    ['c1', 'c2'],
  );
  assert.deepEqual(listConversationsForUser(db, 'bob').map((c) => c.id), ['c1']);
  assert.deepEqual(listConversationsForUser(db, 'dave').map((c) => c.id), []);
});

test('JSONL 导出 -> 导入 往返一致', () => {
  const db1 = openDb();
  upsertConversation(db1, makeConversation());
  upsertMessage(db1, makeMessage());
  const text = exportJsonl(db1);

  const db2 = openDb();
  const res = importJsonl(db2, text);
  assert.equal(res.conversations, 1);
  assert.equal(res.messages, 1);
  assert.equal(countMessages(db2), 1);
  assert.deepEqual(listMessagesForConversation(db2, 'c1')[0], makeMessage());
});

test('合并两份有重叠的导出：无重复记录', () => {
  const db = openDb();
  upsertConversation(db, makeConversation());
  upsertMessage(db, makeMessage({ id: 'm1' }));
  upsertMessage(db, makeMessage({ id: 'm2', content: 'second' }));
  const text = exportJsonl(db);

  importJsonl(db, text);
  importJsonl(db, text); // 再导一遍
  assert.equal(countMessages(db), 2);
});

test('无 UUID 的第三方记录：生成确定性 id，重复导入幂等', () => {
  const db = openDb();
  const line =
    '{"record":"message","conversationId":"cX","senderId":"me","type":"text","content":"hello","createdAt":123}';
  importJsonl(db, line);
  assert.equal(countMessages(db), 1);
  const id1 = listMessagesForConversation(db, 'cX')[0].id;
  assert.equal(id1, deterministicId('cX', 'me', 'hello', 123));

  importJsonl(db, line);
  assert.equal(countMessages(db), 1);
  assert.equal(listMessagesForConversation(db, 'cX')[0].id, id1);
});

test('悬空 conversationId 惰性创建占位会话', () => {
  const db = openDb();
  importJsonl(
    db,
    '{"record":"message","id":"m1","conversationId":"ghost","senderId":"me","type":"text","content":"x","createdAt":1}',
  );
  const conv = getConversation(db, 'ghost');
  assert.ok(conv);
  assert.deepEqual(conv.participants, ['me']);
  assert.equal(conv.type, 'direct');
});
