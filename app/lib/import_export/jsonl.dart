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

// ---- 记录 id 提取（companion 与 preview/skip 共用同一份逻辑） ----

String _conversationId(Map<String, dynamic> r) {
  final id = r['id'];
  if (id is String && id.isNotEmpty) return id;
  return deterministicId('', '', '', 0);
}

String _messageId(Map<String, dynamic> r) {
  final id = r['id'];
  if (id is String && id.isNotEmpty) return id;
  return deterministicId(
    (r['conversationId'] ?? '').toString(),
    (r['senderId'] ?? '').toString(),
    (r['content'] ?? '').toString(),
    (r['createdAt'] as num?)?.toInt() ?? 0,
  );
}

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
  return ConversationsCompanion.insert(
    id: _conversationId(r),
    type: r['type'] == 'group' ? 'group' : 'direct',
    name: Value<String?>(r['name']?.toString()),
    participants: jsonEncode(participants),
    createdAt: (r['createdAt'] as num?)?.toInt() ?? 0,
  );
}

MessagesCompanion messageCompanion(Map<String, dynamic> r) {
  final conversationId = (r['conversationId'] ?? '').toString();
  final senderId = (r['senderId'] ?? '').toString();
  final content = (r['content'] ?? '').toString();
  final createdAt = (r['createdAt'] as num?)?.toInt() ?? 0;
  return MessagesCompanion.insert(
    id: _messageId(r),
    conversationId: conversationId,
    senderId: senderId,
    type: _messageType(r['type']),
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
/// 可按 会话/发送者/时间范围 过滤，语义与服务端 export.ts 一致。
Future<String> exportJsonl(
  AppDatabase db, {
  String? conversationId,
  String? senderId,
  int? from,
  int? to,
}) async {
  final lines = <String>[];
  var convs = conversationId != null
      ? [await db.getConversation(conversationId)]
      : await db.getAllConversations();
  var valid = convs.whereType<Conversation>().toList();

  bool matches(Message m) =>
      (senderId == null || m.senderId == senderId) &&
      (from == null || m.createdAt >= from) &&
      (to == null || m.createdAt <= to);

  // 有消息级过滤时，只保留至少含一条命中消息的会话，避免导出空会话壳。
  if (senderId != null || from != null || to != null) {
    valid = [
      for (final c in valid)
        if ((await db.getMessagesForConversation(c.id)).any(matches)) c,
    ];
  }

  for (final c in valid) {
    lines.add(conversationToLine(c));
  }
  for (final c in valid) {
    for (final m in await db.getMessagesForConversation(c.id)) {
      if (matches(m)) lines.add(messageToLine(m));
    }
  }
  return lines.isEmpty ? '' : '${lines.join('\n')}\n';
}

typedef ImportResult = ({int conversations, int messages});

/// 导入时的冲突处理策略。
enum ImportMode {
  /// 已存在（id 相同）的记录用新值覆盖（原 upsert 行为）。
  overwrite,

  /// 已存在的记录跳过不碰，只插入不存在的（纯新增，保证既有记录不被改动）。
  skipExisting,
}

/// 导入前预览结果：区分「新增」与「已存在」，并进一步区分「内容不同（会被覆盖）」与「完全相同（无变化）」。
class ImportPreview {
  const ImportPreview({
    required this.newConversations,
    required this.existingConversations,
    required this.newMessages,
    required this.changedMessages,
    required this.identicalMessages,
  });

  final int newConversations;

  /// 已存在且 id 相同的会话数（导入时会覆盖或跳过）。
  final int existingConversations;

  final int newMessages;

  /// 已存在且内容不同的消息数（覆盖模式下真正变更，跳过模式下不动）。
  final int changedMessages;

  /// 已存在且内容完全一致的消息数（两种模式下都是无操作）。
  final int identicalMessages;

  /// 若没有新增也没有内容变化，则「导入」实际上无事可做。
  bool get hasChanges =>
      newConversations > 0 || newMessages > 0 || changedMessages > 0;
}

List<Map<String, dynamic>> _parseRecords(String text) {
  final records = <Map<String, dynamic>>[];
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    records.add(jsonDecode(t) as Map<String, dynamic>);
  }
  return records;
}

/// 导入前预览：计算「新增 / 覆盖（内容不同）/ 相同」条数，不写库。
Future<ImportPreview> previewImport(AppDatabase db, String text) async {
  final records = _parseRecords(text);
  final convs = records.where((r) => r['record'] == 'conversation').toList();
  final msgs = records.where((r) => r['record'] == 'message').toList();

  final convIds = convs.map(_conversationId).toSet();
  final msgIds = msgs.map(_messageId).toSet();

  final existingConvs = await db.existingConversationIds(convIds);
  final existingMsgs = await db.messagesByIds(msgIds);

  var newConversations = 0;
  var existingConversations = 0;
  for (final id in convIds) {
    if (existingConvs.contains(id)) {
      existingConversations++;
    } else {
      newConversations++;
    }
  }

  var newMessages = 0;
  var changedMessages = 0;
  var identicalMessages = 0;
  for (final r in msgs) {
    final row = existingMsgs[_messageId(r)];
    if (row == null) {
      newMessages++;
    } else if (_messageEqual(row, r)) {
      identicalMessages++;
    } else {
      changedMessages++;
    }
  }

  return ImportPreview(
    newConversations: newConversations,
    existingConversations: existingConversations,
    newMessages: newMessages,
    changedMessages: changedMessages,
    identicalMessages: identicalMessages,
  );
}

/// 已存在的消息与导入记录是否完全一致（内容 / 类型 / editedAt / metadata）。
bool _messageEqual(Message m, Map<String, dynamic> r) {
  if (m.type != _messageType(r['type'])) return false;
  if (m.content != (r['content'] ?? '').toString()) return false;
  final inEdited =
      r['editedAt'] == null ? null : (r['editedAt'] as num).toInt();
  if (m.editedAt != inEdited) return false;
  try {
    return _deepEqual(jsonDecode(m.metadata), r['metadata'] ?? {});
  } catch (_) {
    return m.metadata == jsonEncode(r['metadata'] ?? {});
  }
}

/// 深度相等：Map/List/标量，忽略 Map 键顺序。
bool _deepEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_deepEqual(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEqual(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// 导入 JSONL 文本：两遍扫描（conversation 先于 message），悬空引用惰性建占位会话。
/// [mode] 控制冲突处理：overwrite 覆盖已有，skipExisting 跳过已有。
Future<ImportResult> importJsonl(
  AppDatabase db,
  String text, {
  ImportMode mode = ImportMode.overwrite,
}) async {
  final records = _parseRecords(text);
  final convs = records.where((r) => r['record'] == 'conversation').toList();
  final msgs = records.where((r) => r['record'] == 'message').toList();

  final existingConvs = mode == ImportMode.skipExisting
      ? await db.existingConversationIds(convs.map(_conversationId).toSet())
      : null;
  final existingMsgs = mode == ImportMode.skipExisting
      ? await db.existingMessageIds(msgs.map(_messageId).toSet())
      : null;

  await db.transaction(() async {
    for (final r in convs) {
      if (existingConvs != null && existingConvs.contains(_conversationId(r))) {
        continue;
      }
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
      if (existingMsgs != null && existingMsgs.contains(_messageId(r))) {
        continue;
      }
      await db.upsertMessage(messageCompanion(r));
    }
  });

  return (conversations: convs.length, messages: msgs.length);
}
