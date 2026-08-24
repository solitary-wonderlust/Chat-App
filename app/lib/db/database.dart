// drift 数据库 + DAO。注意：需要先运行 `dart run build_runner build` 生成 database.g.dart。

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(tables: [Conversations, Messages, Outbox])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'chat_app'));

  AppDatabase.forTesting(QueryExecutor executor) : super(executor);

  @override
  int get schemaVersion => 1;

  // ---- conversations ----

  Future<void> upsertConversation(ConversationsCompanion c) =>
      into(conversations).insertOnConflictUpdate(c);

  Future<Conversation?> getConversation(String id) =>
      (select(conversations)..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<List<Conversation>> getAllConversations() => select(conversations).get();

  Future<List<String>> allConversationIds() async {
    final rows = await select(conversations).get();
    return rows.map((c) => c.id).toList();
  }

  /// 当前用户参与的会话（「按登录用户区分显示」的核心过滤，SQL 之外在 Dart 里完成 JSON 过滤）。
  Stream<List<Conversation>> watchConversationsForUser(String username) =>
      select(conversations).watch().map(
            (rows) => rows
                .where((c) =>
                    (jsonDecode(c.participants) as List).contains(username))
                .toList(),
          );

  // ---- messages ----

  Future<void> upsertMessage(MessagesCompanion m) =>
      into(messages).insertOnConflictUpdate(m);

  Stream<List<Message>> watchMessages(String conversationId) => (select(messages)
        ..where((m) => m.conversationId.equals(conversationId))
        ..orderBy([(m) => OrderingTerm.asc(m.createdAt)]))
      .watch();

  Future<List<Message>> getMessagesForConversation(String conversationId) =>
      (select(messages)
            ..where((m) => m.conversationId.equals(conversationId))
            ..orderBy([(m) => OrderingTerm.asc(m.createdAt)]))
          .get();

  /// 某会话本地最大 created_at，作为增量拉取的游标。
  Future<int> maxMessageCreatedAt(String conversationId) async {
    final row = await customSelect(
      'SELECT MAX(created_at) AS m FROM messages WHERE conversation_id = ?',
      variables: [Variable(conversationId)],
    ).getSingle();
    return row.read<int>('m') ?? 0;
  }

  // ---- outbox ----

  Future<void> enqueueOutbox(OutboxCompanion o) => into(outbox).insert(o);

  Future<List<OutboxData>> pendingOutbox() =>
      (select(outbox)..orderBy([(o) => OrderingTerm.asc(o.createdAt)])).get();

  Future<void> removeOutbox(String id) =>
      (delete(outbox)..where((o) => o.id.equals(id))).go();
}
