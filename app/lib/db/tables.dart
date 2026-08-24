// drift 表定义。与服务器 schema（docs/format.md）保持一致的记录层，
// 另加一张 outbox 作为离线发送队列（记录层 columns 完全一致，不污染 messages 表）。

import 'package:drift/drift.dart';

class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()(); // 'direct' | 'group'
  TextColumn get name => text().nullable()();
  TextColumn get participants => text()(); // JSON 数组字符串 ["alice","bob"]
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text()();
  TextColumn get senderId => text()();
  TextColumn get type => text()(); // 'text' | 'image' | 'file' | 'system'
  TextColumn get content => text()();
  IntColumn get createdAt => integer()(); // epoch 毫秒
  IntColumn get editedAt => integer().nullable()();
  TextColumn get metadata => text()(); // JSON 对象字符串

  @override
  Set<Column> get primaryKey => {id};
}

/// 离线待发送队列：消息先落 messages 表，同时入 outbox，推送成功后删除。
class Outbox extends Table {
  TextColumn get id => text()();
  TextColumn get payload => text()(); // 消息 JSONL 记录 JSON 字符串
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}
