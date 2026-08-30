// 第三方格式转换器测试（阶段 3B）：微信/QQ txt、常见 json → 本格式 JSONL。
// 覆盖：txt 冒号/括号/多行/发送者在先四种布局、json 数组/对象、本格式透传、
// 无法识别返回空、以及「转换后导入可去重」的 DoD。

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/db/database.dart';
import 'package:chat_app/import_export/converters/converters.dart';
import 'package:chat_app/import_export/jsonl.dart';

AppDatabase _memoryDb() => AppDatabase.forTesting(NativeDatabase.memory());

List<Map<String, dynamic>> _messagesOf(String jsonl) => jsonl
    .trim()
    .split('\n')
    .map((l) => jsonDecode(l) as Map<String, dynamic>)
    .where((r) => r['record'] == 'message')
    .toList();

Map<String, dynamic> _conversationOf(String jsonl) => jsonDecode(
      jsonl.trim().split('\n').first,
    ) as Map<String, dynamic>;

void main() {
  group('txt（微信格式，冒号分隔）', () {
    test('解析 4 条消息为 1 个会话，参与者包含 me', () {
      final res = convertThirdParty(
        '2024-01-15 09:30:00 张三: 早上好\n'
        '2024-01-15 09:31:02 李四: 早！吃了吗\n'
        '2024-01-15 09:35:10 张三: 吃了，去上班\n'
        '2024-01-15 09:35:44 李四: 好嘞，回头聊\n',
        me: 'alice',
      );
      expect(res.conversations, 1);
      expect(res.messages, 4);

      final conv = _conversationOf(res.jsonl);
      expect(conv['record'], 'conversation');
      expect(conv['type'], 'direct');
      expect((conv['participants'] as List).toSet(), {'张三', '李四', 'alice'});

      final msgs = _messagesOf(res.jsonl);
      expect(msgs[0]['senderId'], '张三');
      expect(msgs[0]['content'], '早上好');
      expect(msgs[1]['senderId'], '李四');
      expect(
        msgs[0]['createdAt'],
        DateTime(2024, 1, 15, 9, 30).millisecondsSinceEpoch,
      );
    });

    test('确定性 id：重复转换结果一致（幂等去重）', () {
      const text = '2024-01-15 09:30:00 张三: 你好\n';
      final a = convertThirdParty(text, me: 'alice');
      final b = convertThirdParty(text, me: 'alice');
      expect(a.jsonl, b.jsonl);
      expect(a.messages, 1);
    });

    test('空内容消息（纯发送者头）被丢弃', () {
      final res = convertThirdParty(
        '2024-01-15 09:30:00 张三:\n'
        '2024-01-15 09:31:00 李四: 来了\n',
      );
      expect(res.messages, 1);
      expect(_messagesOf(res.jsonl).single['content'], '来了');
    });
  });

  group('txt（QQ 格式，括号备注 + 多行内容）', () {
    test('括号内 QQ 号被忽略，后续行折叠为一条消息', () {
      final res = convertThirdParty(
        '2024-02-01 20:00:00 张三(10001)\n'
        '在吗？\n'
        '2024-02-01 20:05:32 李四(10002)\n'
        '在的，啥事\n'
        '第二行内容\n',
        me: 'alice',
      );
      expect(res.conversations, 1);
      expect(res.messages, 2);
      final msgs = _messagesOf(res.jsonl);
      expect(msgs[0]['senderId'], '张三');
      expect(msgs[0]['content'], '在吗？');
      expect(msgs[1]['senderId'], '李四');
      expect(msgs[1]['content'], '在的，啥事\n第二行内容');
    });
  });

  group('txt（发送者在先的行）', () {
    test('作者 + 时间行，内容在下一行', () {
      final res = convertThirdParty(
        '张三 2024-03-01 10:00:00\n'
        '第一条\n'
        '李四 2024-03-01 10:05:00\n'
        '第二条\n',
      );
      expect(res.messages, 2);
      final msgs = _messagesOf(res.jsonl);
      expect(msgs[0]['senderId'], '张三');
      expect(msgs[0]['content'], '第一条');
      expect(msgs[1]['senderId'], '李四');
      expect(msgs[1]['content'], '第二条');
    });
  });

  group('json', () {
    test('数组消息 → 1 会话 N 消息，参与者并入 me', () {
      final res = convertThirdParty(
        '[{"sender":"alice","content":"hello","time":1700000000000},'
        '{"sender":"bob","content":"hi","time":1700000001000}]',
        me: 'carol',
      );
      expect(res.conversations, 1);
      expect(res.messages, 2);
      final conv = _conversationOf(res.jsonl);
      expect((conv['participants'] as List).toSet(), {'alice', 'bob', 'carol'});
      final msgs = _messagesOf(res.jsonl);
      expect(msgs[0]['content'], 'hello');
      expect(msgs[0]['createdAt'], 1700000000000);
    });

    test('{messages:[...]} 结构可解析', () {
      final res = convertThirdParty(
        '{"messages":[{"from":"alice","msg":"a","timestamp":1700000000000}]}',
      );
      expect(res.messages, 1);
      expect(_messagesOf(res.jsonl).single['content'], 'a');
    });
  });

  group('本格式 JSONL 透传', () {
    test('统计条数并原样返回', () {
      const jsonl = '{"record":"conversation","id":"c1","type":"direct",'
          '"name":null,"participants":["a","b"],"createdAt":1}\n'
          '{"record":"message","id":"m1","conversationId":"c1","senderId":"a",'
          '"type":"text","content":"hi","createdAt":1,"editedAt":null,"metadata":{}}\n';
      final res = convertThirdParty(jsonl);
      expect(res.conversations, 1);
      expect(res.messages, 1);
      expect(res.jsonl.trim(), jsonl.trim());
    });
  });

  group('无法识别', () {
    test('空 / 垃圾文本返回空结果', () {
      expect(convertThirdParty('').isEmpty, isTrue);
      expect(convertThirdParty('随便一段没有时间戳的文本').isEmpty, isTrue);
    });
  });

  group('转换后导入可去重（DoD）', () {
    test('微信样例 txt → 导入两次不产生重复', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final res = convertThirdParty(
        File('test/fixtures/wechat.txt').readAsStringSync(),
        me: 'alice',
      );
      final r1 = await importJsonl(db, res.jsonl);
      final r2 = await importJsonl(db, res.jsonl);
      expect(r1.messages, 4);
      expect(r2.messages, 4);

      final convs = await db.getAllConversations();
      expect(convs.length, 1);
      expect(await db.getMessagesForConversation(convs.single.id), hasLength(4));
    });

    test('QQ 样例 txt → 多行内容正确 + 去重', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final res = convertThirdParty(
        File('test/fixtures/qq.txt').readAsStringSync(),
        me: 'alice',
      );
      expect(res.messages, 2);
      final msgs = _messagesOf(res.jsonl);
      expect(msgs[1]['content'], '在的，啥事\n第二行内容');

      final r1 = await importJsonl(db, res.jsonl);
      await importJsonl(db, res.jsonl);
      expect(r1.messages, 2);
      final convs = await db.getAllConversations();
      expect(await db.getMessagesForConversation(convs.single.id), hasLength(2));
    });

    test('JSON 样例 → 导入后按发送者/时间还原', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final res = convertThirdParty(
        File('test/fixtures/wechat.json').readAsStringSync(),
        me: 'alice',
      );
      await importJsonl(db, res.jsonl);
      final convs = await db.getAllConversations();
      expect(convs.single.type, 'direct');
      final msgs = await db.getMessagesForConversation(convs.single.id);
      expect(msgs, hasLength(2));
      expect(msgs.first.senderId, 'alice');
      expect(msgs.last.senderId, 'bob');
    });
  });
}
