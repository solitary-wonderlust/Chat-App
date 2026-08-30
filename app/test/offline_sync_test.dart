// 客户端「记录层 + 编排层」测试：不依赖真机与网络，DB 用内存（NativeDatabase.memory）。
//
// 覆盖三条核心不变量：
//   1. 会话过滤 —— 按当前登录用户 participants 过滤，只显示自己参与的会话；
//   2. 发送入 outbox —— 发消息先落本地 messages，同时入 outbox（离线优先）；
//   3. 增量同步游标 —— 游标 = 会话内 MAX(created_at)，upsert-by-id 幂等不重复。

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/api/api_client.dart';
import 'package:chat_app/auth/session.dart';
import 'package:chat_app/db/database.dart';
import 'package:chat_app/service.dart';

AppDatabase _memoryDb() => AppDatabase.forTesting(NativeDatabase.memory());

void main() {
  group('会话过滤（按登录用户 participants）', () {
    test('只显示当前用户参与的会话', () async {
      final db = _memoryDb();
      addTearDown(db.close);

      await db.upsertConversation(ConversationsCompanion.insert(
        id: 'c1',
        type: 'direct',
        participants: jsonEncode(['alice', 'bob']),
        createdAt: 1,
      ));
      await db.upsertConversation(ConversationsCompanion.insert(
        id: 'c2',
        type: 'direct',
        participants: jsonEncode(['bob', 'carol']),
        createdAt: 2,
      ));
      await db.upsertConversation(ConversationsCompanion.insert(
        id: 'c3',
        type: 'group',
        name: Value<String?>('三国群'),
        participants: jsonEncode(['alice', 'carol']),
        createdAt: 3,
      ));

      final alice = await db.watchConversationsForUser('alice').first;
      expect(alice.map((c) => c.id).toSet(), {'c1', 'c3'});

      final bob = await db.watchConversationsForUser('bob').first;
      expect(bob.map((c) => c.id).toSet(), {'c1', 'c2'});

      // 不参与任何会话的用户看不到任何会话。
      final dave = await db.watchConversationsForUser('dave').first;
      expect(dave, isEmpty);
    });
  });

  group('发送入 outbox（离线优先）', () {
    test('发消息后本地 messages +1 且 outbox 入队一条', () async {
      final db = _memoryDb();
      addTearDown(db.close);

      await db.upsertConversation(ConversationsCompanion.insert(
        id: 'c1',
        type: 'direct',
        participants: jsonEncode(['alice', 'bob']),
        createdAt: 1,
      ));

      // 用始终抛错的 MockClient 模拟离线：push 失败会中断，outbox 保留待发。
      final api = ApiClient(
        'http://localhost:3000',
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      final service = ChatService(
        db: db,
        api: api,
        session: const Session(
          token: 'token',
          userId: 'u-alice',
          username: 'alice',
          serverUrl: 'http://localhost:3000',
        ),
      );

      final before = await db.getMessagesForConversation('c1');
      await service.sendMessage('c1', '你好');
      // 让 fire-and-forget 的 pushOutbox 跑完（离线失败即中断），避免残留未决 future。
      await Future<void>.delayed(Duration.zero);

      final after = await db.getMessagesForConversation('c1');
      expect(after.length, before.length + 1);
      final sent = after.last;
      expect(sent.senderId, 'alice');
      expect(sent.content, '你好');
      expect(sent.type, 'text');

      final outbox = await db.pendingOutbox();
      expect(outbox.length, 1);
      expect(outbox.first.id, sent.id);

      // outbox 的 payload 是可重投递的消息记录，供恢复网络后重发。
      final payload = jsonDecode(outbox.first.payload) as Map<String, dynamic>;
      expect(payload['record'], 'message');
      expect(payload['conversationId'], 'c1');
      expect(payload['content'], '你好');
    });
  });

  group('增量同步游标 + 幂等合并', () {
    test('游标为会话内 MAX(created_at)，重复 upsert 不产生副本', () async {
      final db = _memoryDb();
      addTearDown(db.close);

      // 空会话无消息：MAX 为 NULL，游标回退为 0（不抛错）。
      expect(await db.maxMessageCreatedAt('empty'), 0);

      Future<void> put(String id, int at) => db.upsertMessage(
            MessagesCompanion.insert(
              id: id,
              conversationId: 'c1',
              senderId: id == 'm2' ? 'bob' : 'alice',
              type: 'text',
              content: 'msg-$id',
              createdAt: at,
              metadata: '{}',
            ),
          );

      await put('m1', 100);
      await put('m2', 300);
      await put('m3', 200);

      // 增量拉取的游标 = 本地该会话的最大 created_at。
      expect(await db.maxMessageCreatedAt('c1'), 300);

      // 重新 upsert 同一 id（模拟重复同步 / 导入合并）：覆盖内容而非新增一行。
      await db.upsertMessage(MessagesCompanion.insert(
        id: 'm2',
        conversationId: 'c1',
        senderId: 'bob',
        type: 'text',
        content: 'msg-m2-edited',
        createdAt: 300,
        metadata: '{}',
      ));

      final all = await db.getMessagesForConversation('c1');
      expect(all.length, 3);
      expect(all.map((m) => m.id).toSet(), {'m1', 'm2', 'm3'});
      expect(all.firstWhere((m) => m.id == 'm2').content, 'msg-m2-edited');
    });
  });
}
