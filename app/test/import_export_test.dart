// 阶段 3：导入预览与冲突处理（3C）+ 服务器互导（3A）。
// 覆盖：previewImport 区分新增/覆盖/相同；importJsonl 的 overwrite / skipExisting 模式；
// service.importToServer / exportFromServer / convertImportText。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chat_app/api/api_client.dart';
import 'package:chat_app/auth/session.dart';
import 'package:chat_app/db/database.dart';
import 'package:chat_app/import_export/jsonl.dart';
import 'package:chat_app/service.dart';

AppDatabase _memoryDb() => AppDatabase.forTesting(NativeDatabase.memory());

const _alice = Session(
  token: 'token',
  userId: 'u-alice',
  username: 'alice',
  serverUrl: 'http://localhost:3000',
);

String _convLine(String id) => jsonEncode({
      'record': 'conversation',
      'id': id,
      'type': 'direct',
      'name': null,
      'participants': ['alice', 'bob'],
      'createdAt': 1,
    });

String _msgLine(
  String id, {
  String convId = 'c1',
  String sender = 'alice',
  String content = '内容',
  int createdAt = 100,
  int? editedAt,
  Map<String, dynamic>? metadata,
}) =>
    jsonEncode({
      'record': 'message',
      'id': id,
      'conversationId': convId,
      'senderId': sender,
      'type': 'text',
      'content': content,
      'createdAt': createdAt,
      'editedAt': editedAt,
      'metadata': metadata ?? const <String, dynamic>{},
    });

Future<void> _seed(AppDatabase db) async {
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
    content: '旧内容',
    createdAt: 100,
    metadata: '{}',
  ));
}

void main() {
  group('previewImport（导入预览，3C）', () {
    test('空库 + 全新增 → new 计数', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final text = '${_convLine('c1')}\n${_msgLine('m1')}\n';
      final p = await previewImport(db, text);
      expect(p.newConversations, 1);
      expect(p.existingConversations, 0);
      expect(p.newMessages, 1);
      expect(p.changedMessages, 0);
      expect(p.identicalMessages, 0);
      expect(p.hasChanges, isTrue);
    });

    test('已存在且内容相同 → identical 计数', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      await _seed(db);
      final text = '${_convLine('c1')}\n'
          '${_msgLine('m1', content: '旧内容')}\n'
          '${_msgLine('m1', content: '旧内容')}\n'; // 同 id 重复行
      final p = await previewImport(db, text);
      expect(p.existingConversations, 1);
      expect(p.newMessages, 0);
      expect(p.changedMessages, 0);
      expect(p.identicalMessages, 2);
      expect(p.hasChanges, isFalse);
    });

    test('已存在 id 但内容不同 → changedMessages 计数', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      await _seed(db);
      final text = '${_convLine('c1')}\n'
          '${_msgLine('m1', content: '被改过的新内容')}\n';
      final p = await previewImport(db, text);
      expect(p.existingConversations, 1);
      expect(p.newMessages, 0);
      expect(p.changedMessages, 1);
      expect(p.identicalMessages, 0);
      expect(p.hasChanges, isTrue);
    });
  });

  group('importJsonl 合并模式（3C）', () {
    test('overwrite（默认）：已存在记录被覆盖', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      await _seed(db);
      await importJsonl(db, '${_convLine('c1')}\n${_msgLine('m1', content: '新内容')}\n');
      final m = (await db.getMessagesForConversation('c1')).single;
      expect(m.content, '新内容');
    });

    test('skipExisting：已存在记录不被覆盖，新增照常插入', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      await _seed(db);
      final text = '${_convLine('c1')}\n'
          '${_msgLine('m1', content: '尝试覆盖旧内容')}\n'
          '${_msgLine('m2', content: '新增消息')}\n';
      await importJsonl(db, text, mode: ImportMode.skipExisting);
      final msgs = await db.getMessagesForConversation('c1');
      expect(msgs, hasLength(2));
      final m1 = msgs.firstWhere((m) => m.id == 'm1');
      expect(m1.content, '旧内容'); // 未被覆盖
      final m2 = msgs.firstWhere((m) => m.id == 'm2');
      expect(m2.content, '新增消息');
    });
  });

  group('service 服务器互导（3A）', () {
    test('importToServer：POST /import 携带 JSONL，解析返回条数', () async {
      final api = ApiClient(
        'http://localhost:3000',
        client: MockClient((req) async {
          expect(req.method, 'POST');
          expect(req.url.path, '/import');
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          expect((body['text'] as String).contains('{"record":'), isTrue);
          return http.Response(
            jsonEncode({'conversations': 1, 'messages': 2}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final service = ChatService(
        db: _memoryDb(),
        api: api,
        session: _alice,
      );
      final r = await service.importToServer('${_convLine('c1')}\n${_msgLine('m1')}\n');
      expect(r.conversations, 1);
      expect(r.messages, 2);
    });

    test('exportFromServer：GET /export 返回服务器 JSONL 文本', () async {
      const serverJsonl =
          '{"record":"conversation","id":"c1","type":"direct","name":null,'
          '"participants":["alice","bob"],"createdAt":1}\n'
          '{"record":"message","id":"m1","conversationId":"c1","senderId":"bob",'
          '"type":"text","content":"来自服务器","createdAt":2,"editedAt":null,"metadata":{}}\n';
      final api = ApiClient(
        'http://localhost:3000',
        client: MockClient((req) async {
          expect(req.method, 'GET');
          expect(req.url.path, '/export');
          return http.Response(
            serverJsonl,
            200,
            headers: {'content-type': 'application/x-ndjson; charset=utf-8'},
          );
        }),
      );
      final service = ChatService(db: _memoryDb(), api: api, session: _alice);
      final text = await service.exportFromServer();
      expect(text.trim(), serverJsonl.trim());
    });

    test('convertImportText：微信 txt 转换并把当前用户名并入 participants', () async {
      final service = ChatService(
        db: _memoryDb(),
        api: ApiClient('http://localhost:3000'),
        session: _alice,
      );
      final res = service.convertImportText('2024-01-01 10:00:00 bob: 你好\n');
      expect(res.messages, 1);
      final conv =
          jsonDecode(res.jsonl.trim().split('\n').first) as Map<String, dynamic>;
      expect((conv['participants'] as List).contains('alice'), isTrue);
      expect((conv['participants'] as List).contains('bob'), isTrue);
    });
  });
}
