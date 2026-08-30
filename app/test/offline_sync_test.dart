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

  group('附件上传（sendAttachment）', () {
    test('上传成功 → 落本地 image 消息（含 metadata）+ 入 outbox', () async {
      final db = _memoryDb();
      addTearDown(db.close);

      await db.upsertConversation(ConversationsCompanion.insert(
        id: 'c1',
        type: 'direct',
        participants: jsonEncode(['alice', 'bob']),
        createdAt: 1,
      ));

      // Mock POST /attachments 返回相对 url；其余路径 404（push 中断、outbox 保留）。
      final api = ApiClient(
        'http://localhost:3000',
        client: MockClient((req) async {
          if (req.url.path == '/attachments') {
            expect(req.headers['content-type'], 'image/png');
            expect(req.headers['authorization'], 'Bearer token');
            expect(req.headers['x-filename'], Uri.encodeComponent('照片.png'));
            return http.Response(
              jsonEncode({
                'url': '/attachments/abc/照片.png',
                'name': '照片.png',
                'size': 42,
                'mime': 'image/png',
              }),
              201,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('not found', 404);
        }),
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

      final bytes = Uint8List.fromList(List.generate(42, (i) => i));
      await service.sendAttachment('c1', bytes, '照片.png', 'image/png');
      // fire-and-forget 的 pushOutbox 跑完（404 中断、outbox 保留），避免残留未决 future。
      await Future<void>.delayed(Duration.zero);

      final msgs = await db.getMessagesForConversation('c1');
      expect(msgs.length, 1);
      final m = msgs.single;
      expect(m.type, 'image');
      expect(m.content, '/attachments/abc/照片.png');

      final meta = jsonDecode(m.metadata) as Map<String, dynamic>;
      expect(meta['name'], '照片.png');
      expect(meta['size'], 42);
      expect(meta['mime'], 'image/png');

      final outbox = await db.pendingOutbox();
      expect(outbox.length, 1);
      expect(outbox.first.id, m.id);
    });

    test('非图片 mime 落 file 消息', () async {
      final db = _memoryDb();
      addTearDown(db.close);

      await db.upsertConversation(ConversationsCompanion.insert(
        id: 'c1',
        type: 'direct',
        participants: jsonEncode(['alice', 'bob']),
        createdAt: 1,
      ));
      final api = ApiClient(
        'http://localhost:3000',
        client: MockClient((req) async => req.url.path == '/attachments'
            ? http.Response(
                jsonEncode({
                  'url': '/attachments/xyz/note.pdf',
                  'name': 'note.pdf',
                  'size': 100,
                  'mime': 'application/pdf',
                }),
                201,
              )
            : http.Response('not found', 404)),
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

      await service.sendAttachment(
        'c1',
        Uint8List.fromList(List.filled(100, 1)),
        'note.pdf',
        'application/pdf',
      );
      await Future<void>.delayed(Duration.zero);

      final m = (await db.getMessagesForConversation('c1')).single;
      expect(m.type, 'file');
      expect(m.content, '/attachments/xyz/note.pdf');
    });
  });

  group('消息搜索（GET /search）', () {
    test('请求携带关键词，返回解析为消息列表', () async {
      final api = ApiClient(
        'http://localhost:3000',
        client: MockClient((req) async {
          expect(req.method, 'GET');
          expect(req.url.path, '/search');
          expect(req.url.queryParameters['q'], '你好');
          return http.Response(
            jsonEncode([
              {
                'record': 'message',
                'id': 'm1',
                'conversationId': 'c1',
                'senderId': 'bob',
                'type': 'text',
                'content': '你好',
                'createdAt': 1,
                'editedAt': null,
                'metadata': <String, dynamic>{},
              },
            ]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final res = await api.searchMessages('token', query: '你好');
      expect(res, hasLength(1));
      expect((res.single as Map)['content'], '你好');
    });
  });

  group('导出过滤（service.exportLocalJsonl）', () {
    late AppDatabase db;
    late ChatService service;

    setUp(() async {
      db = _memoryDb();
      addTearDown(db.close);
      await db.upsertConversation(ConversationsCompanion.insert(
        id: 'c1',
        type: 'direct',
        participants: jsonEncode(['alice', 'bob']),
        createdAt: 1,
      ));
      await db.upsertMessage(MessagesCompanion.insert(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'alice',
        type: 'text',
        content: 'from-alice',
        createdAt: 100,
        metadata: '{}',
      ));
      await db.upsertMessage(MessagesCompanion.insert(
        id: 'm2',
        conversationId: 'c1',
        senderId: 'bob',
        type: 'text',
        content: 'from-bob',
        createdAt: 200,
        metadata: '{}',
      ));
      await db.upsertMessage(MessagesCompanion.insert(
        id: 'm3',
        conversationId: 'c1',
        senderId: 'alice',
        type: 'text',
        content: 'from-alice-late',
        createdAt: 300,
        metadata: '{}',
      ));
      service = ChatService(
        db: db,
        api: ApiClient('http://localhost:3000'),
        session: const Session(
          token: 't',
          userId: 'u',
          username: 'alice',
          serverUrl: 'http://localhost:3000',
        ),
      );
    });

    List<Map<String, dynamic>> messagesOf(String text) => text
        .trim()
        .split('\n')
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .where((r) => r['record'] == 'message')
        .toList();

    test('按发送者过滤：只含该发送者的消息与相关会话', () async {
      final text = await service.exportLocalJsonl(senderId: 'bob');
      final msgs = messagesOf(text);
      expect(msgs.length, 1);
      expect(msgs.single['content'], 'from-bob');

      final convs = text
          .trim()
          .split('\n')
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .where((r) => r['record'] == 'conversation');
      expect(convs.length, 1);
    });

    test('按时间范围过滤：只含区间内消息', () async {
      final text = await service.exportLocalJsonl(from: 150, to: 250);
      final msgs = messagesOf(text);
      expect(msgs.length, 1);
      expect(msgs.single['content'], 'from-bob');
    });

    test('会话 + 发送者 + 时间组合过滤', () async {
      final text = await service.exportLocalJsonl(
        conversationId: 'c1',
        senderId: 'alice',
        from: 150,
      );
      final msgs = messagesOf(text);
      expect(msgs.length, 1);
      expect(msgs.single['content'], 'from-alice-late');
    });
  });

  group('编辑 / 撤回 / 已读（2C）', () {
    const alice = Session(
      token: 'token',
      userId: 'u-alice',
      username: 'alice',
      serverUrl: 'http://localhost:3000',
    );

    Future<AppDatabase> seedDb() async {
      final db = _memoryDb();
      addTearDown(db.close);
      await db.upsertConversation(ConversationsCompanion.insert(
        id: 'c1',
        type: 'direct',
        participants: jsonEncode(['alice', 'bob']),
        createdAt: 1,
      ));
      await db.upsertMessage(MessagesCompanion.insert(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'alice',
        type: 'text',
        content: 'original',
        createdAt: 100,
        metadata: '{}',
      ));
      return db;
    }

    test('编辑：PATCH 后本地 upsert 更新后的记录', () async {
      final db = await seedDb();
      final api = ApiClient(
        'http://localhost:3000',
        client: MockClient((req) async {
          expect(req.method, 'PATCH');
          expect(req.url.path, '/messages/m1');
          expect(jsonDecode(req.body)['content'], 'edited');
          return http.Response(
            jsonEncode({
              'record': 'message',
              'id': 'm1',
              'conversationId': 'c1',
              'senderId': 'alice',
              'type': 'text',
              'content': 'edited',
              'createdAt': 100,
              'editedAt': 200,
              'metadata': <String, dynamic>{},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final service = ChatService(db: db, api: api, session: alice);

      await service.editMessage('c1', 'm1', 'edited');

      final m = (await db.getMessagesForConversation('c1')).single;
      expect(m.content, 'edited');
      expect(m.editedAt, 200);
    });

    test('撤回：DELETE 后本地存墓碑（content 清空 + metadata.deleted）', () async {
      final db = await seedDb();
      final api = ApiClient(
        'http://localhost:3000',
        client: MockClient((req) async {
          expect(req.method, 'DELETE');
          expect(req.url.path, '/messages/m1');
          return http.Response(
            jsonEncode({
              'record': 'message',
              'id': 'm1',
              'conversationId': 'c1',
              'senderId': 'alice',
              'type': 'text',
              'content': '',
              'createdAt': 100,
              'editedAt': 200,
              'metadata': {'deleted': true},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final service = ChatService(db: db, api: api, session: alice);

      await service.deleteMessage('c1', 'm1');

      final m = (await db.getMessagesForConversation('c1')).single;
      expect(m.content, '');
      expect((jsonDecode(m.metadata) as Map)['deleted'], true);
    });

    test('已读：markRead 上报本地最大游标；conversationReads 返回对方游标', () async {
      final db = await seedDb();
      await db.upsertMessage(MessagesCompanion.insert(
        id: 'm2',
        conversationId: 'c1',
        senderId: 'alice',
        type: 'text',
        content: 'later',
        createdAt: 200,
        metadata: '{}',
      ));
      final api = ApiClient(
        'http://localhost:3000',
        client: MockClient((req) async {
          if (req.method == 'POST' && req.url.path == '/conversations/c1/read') {
            expect(jsonDecode(req.body)['upTo'], 200);
            return http.Response(
              jsonEncode({'ok': true, 'upTo': 200}),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (req.method == 'GET' && req.url.path == '/conversations/c1/read') {
            return http.Response(
              jsonEncode([
                {'username': 'bob', 'upTo': 150},
              ]),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('not found', 404);
        }),
      );
      final service = ChatService(db: db, api: api, session: alice);

      await service.markConversationRead('c1');
      final reads = await service.conversationReads('c1');
      expect(reads, {'bob': 150});
    });
  });
}
