// JSONL 编解码与导入/导出。与服务器 server/src/format.ts + export.ts 保持完全一致。
// 规则见 docs/format.md。

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';

const _uuid = Uuid();

// 确定性 id 的分隔符（NUL），避免字段内容在拼接时撞车。
final String _sep = String.fromCharCode(0);

String newId() => _uuid.v4();

/// 为无 id 的第三方记录生成确定性 id（SHA-1 hex），幂等去重。
String deterministicId(
  String conversationId,
  String senderId,
  String content,
  int createdAt,
) =>
    sha1
        .convert(
            utf8.encode([conversationId, senderId, content, '$createdAt'].join(_sep)))
        .toString();

// ---- 行 -> JSONL 行 ----

String conversationToLine(Conversation c) => jsonEncode({
      'record': 'conversation',
      'id': c.id,
      'type': c.type,
      'name': c.name,
      'participants': jsonDecode(c.participants),
      'createdAt': c.createdAt,
    });

String messageToLine(Message m) => jsonEncode({
      'record': 'message',
      'id': m.id,
      'conversationId': m.conversationId,
      'senderId': m.senderId,
      'type': m.type,
      'content': m.content,
      'createdAt': m.createdAt,
      'editedAt': m.editedAt,
      'metadata': jsonDecode(m.metadata),
    });

// ---- JSON 记录 -> companion ----

ConversationsCompanion conversationCompanion(Map<String, dynamic> r) {
  final participants = (r['participants'] is List)
      ? (r['participants'] as List).map((e) => e.toString()).toList()
      : <String>[];
  final id = (r['id'] is String && (r['id'] as String).isNotEmpty)
      ? r['id'] as String
      : deterministicId('', '', '', 0);
  return ConversationsCompanion.insert(
    id: id,
    type: r['type'] == 'group' ? 'group' : 'direct',
    name: Value(r['name'] == null ? null : r['name'].toString()),
    participants: jsonEncode(participants),
    createdAt: (r['createdAt'] as num?)?.toInt() ?? 0,
  );
}

MessagesCompanion messageCompanion(Map<String, dynamic> r) {
  final conversationId = (r['conversationId'] ?? '').toString();
  final senderId = (r['senderId'] ?? '').toString();
  final content = (r['content'] ?? '').toString();
  final createdAt = (r['createdAt'] as num?)?.toInt() ?? 0;
  final id = (r['id'] is String && (r['id'] as String).isNotEmpty)
      ? r['id'] as String
      : deterministicId(conversationId, senderId, content, createdAt);
  final type = _messageType(r['type']);
  return MessagesCompanion.insert(
    id: id,
    conversationId: conversationId,
    senderId: senderId,
    type: type,
    content: content,
    createdAt: createdAt,
    editedAt: Value(r['editedAt'] == null ? null : (r['editedAt'] as num).toInt()),
    metadata: jsonEncode(r['metadata'] ?? {}),
  );
}

String _messageType(Object? t) {
  const valid = {'text', 'image', 'file', 'system'};
  return valid.contains(t) ? t as String : 'text';
}

// ---- 导入 / 导出 ----

/// 导出 JSONL 文本：先 conversation 行，再 message 行。
Future<String> exportJsonl(AppDatabase db, {String? conversationId}) async {
  final lines = <String>[];
  final convs = conversationId != null
      ? [await db.getConversation(conversationId)]
      : await db.getAllConversations();
  final valid = convs.whereType<Conversation>().toList();
  for (final c in valid) {
    lines.add(conversationToLine(c));
  }
  for (final c in valid) {
    for (final m in await db.getMessagesForConversation(c.id)) {
      lines.add(messageToLine(m));
    }
  }
  return lines.isEmpty ? '' : '${lines.join('\n')}\n';
}

typedef ImportResult = ({int conversations, int messages});

/// 导入 JSONL 文本：两遍扫描（conversation 先于 message），悬空引用惰性建占位会话。
Future<ImportResult> importJsonl(AppDatabase db, String text) async {
  final records = <Map<String, dynamic>>[];
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    records.add(jsonDecode(t) as Map<String, dynamic>);
  }

  final convs = records.where((r) => r['record'] == 'conversation').toList();
  final msgs = records.where((r) => r['record'] == 'message').toList();

  await db.transaction(() async {
    for (final r in convs) {
      await db.upsertConversation(conversationCompanion(r));
    }
    for (final r in msgs) {
      final convId = (r['conversationId'] ?? '').toString();
      if (await db.getConversation(convId) == null) {
        await db.upsertConversation(ConversationsCompanion.insert(
          id: convId,
          type: 'direct',
          participants: jsonEncode([(r['senderId'] ?? '').toString()]),
          createdAt: (r['createdAt'] as num?)?.toInt() ?? 0,
        ));
      }
      await db.upsertMessage(messageCompanion(r));
    }
  });

  return (conversations: convs.length, messages: msgs.length);
}
