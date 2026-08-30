// 第三方聊天导出（微信 / QQ 等 txt/json）→ 本格式 JSONL 的转换器。
//
// 独立于 jsonl.dart 的编解码；产出的 JSONL 可直接 importJsonl 或 POST /import。
// 说明：第三方格式没有统一规范，这里按常见布局做启发式解析：
//   txt  —— 每行「时间 + 发送者[: 内容]」，或「发送者 + 时间」；无标记的发送者行后
//           跟的内容行会折叠到上一条；空内容消息丢弃。时间可带 [ ]、可用 - / . 分隔。
//   json —— 兼容常见消息数组 / {messages:[...]} 结构，字段名大小写不敏感映射。
// 无 id 的记录用确定性 id（sha1），保证重复导入幂等去重。

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../jsonl.dart' show deterministicId;

final String _sep = String.fromCharCode(0);

/// 无 id 的第三方会话：按 (参与者排序, 最早消息时间) 生成确定性 id。
String deterministicConversationId(List<String> participants, int createdAt) {
  final names = [...participants]..sort();
  return sha1
      .convert(utf8.encode('${names.join(_sep)}$_sep$createdAt'))
      .toString();
}

/// 转换结果：[jsonl] 可直接导入；[conversations] / [messages] 供展示与空结果判断。
class ConvertResult {
  const ConvertResult({
    required this.jsonl,
    required this.conversations,
    required this.messages,
  });

  final String jsonl;
  final int conversations;
  final int messages;

  bool get isEmpty => conversations == 0 && messages == 0;
}

/// 把第三方导出文本转成本格式 JSONL。
/// [me] 为当前登录用户名：传入时并入各会话 participants，确保导入后「按登录用户区分显示」可见。
///
/// 自动识别顺序：已是本格式 JSONL → 透传；JSON（数组/对象）→ 消息列表映射；否则按 txt 逐行解析。
ConvertResult convertThirdParty(String text, {String? me}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return const ConvertResult(jsonl: '', conversations: 0, messages: 0);
  }

  final own = _convertOwnJsonl(trimmed);
  if (own != null) return own;

  if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
    final fromJson = _convertJson(trimmed, me: me);
    if (!fromJson.isEmpty) return fromJson;
  }

  return _convertTxt(trimmed, me: me);
}

// ---- 本格式 JSONL 透传 ----

ConvertResult? _convertOwnJsonl(String text) {
  var conversations = 0;
  var messages = 0;
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (!t.startsWith('{"record"')) return null;
    try {
      final r = jsonDecode(t) as Map<String, dynamic>;
      if (r['record'] == 'conversation') {
        conversations++;
      } else if (r['record'] == 'message') {
        messages++;
      } else {
        return null;
      }
    } catch (_) {
      return null;
    }
  }
  if (conversations == 0 && messages == 0) return null;
  return ConvertResult(
    jsonl: text.endsWith('\n') ? text : '$text\n',
    conversations: conversations,
    messages: messages,
  );
}

// ---- JSON 消息列表 ----

const _senderKeys = [
  'senderid',
  'sender_id',
  'sender',
  'from',
  'fromuser',
  'username',
  'nickname',
  'nick',
  'user',
  'name',
];
const _contentKeys = ['content', 'text', 'msg', 'message', 'body'];
const _convKeys = [
  'conversationid',
  'conversation_id',
  'sessionid',
  'session',
  'room',
  'chatid',
  'cid',
];
const _timeKeys = [
  'createdat',
  'created_at',
  'time',
  'timestamp',
  'createtime',
  'date',
  'msgtime',
];
const _typeKeys = ['type', 'msgtype', 'messagetype'];
const _metaKeys = ['metadata', 'extra', 'ext'];

/// JSON 键一律转小写，避免大小写不一致导致漏字段。
Map<String, dynamic> _normalizeKeys(Map<dynamic, dynamic> m) {
  final out = <String, dynamic>{};
  m.forEach((k, v) {
    final key = k.toString();
    if (key.isEmpty) return;
    out[key.toLowerCase()] = v;
  });
  return out;
}

String _pick(List<String> keys, Map<String, dynamic> m) {
  for (final k in keys) {
    final v = m[k];
    if (v != null && v.toString().isNotEmpty) return v.toString();
  }
  return '';
}

/// 返回第一个存在的原始值（供 time / metadata 等非字符串字段使用）。
Object? _pickValue(List<String> keys, Map<String, dynamic> m) {
  for (final k in keys) {
    if (m.containsKey(k)) return m[k];
  }
  return null;
}

ConvertResult _convertJson(String text, {String? me}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return const ConvertResult(jsonl: '', conversations: 0, messages: 0);
  }

  List<dynamic> items;
  if (decoded is List) {
    items = decoded;
  } else if (decoded is Map) {
    final norm = _normalizeKeys(decoded);
    final list = norm['messages'] ?? norm['list'] ?? norm['data'] ?? norm['records'];
    if (list is List) {
      items = list;
    } else if (_isMessageLike(norm)) {
      items = [norm];
    } else {
      return const ConvertResult(jsonl: '', conversations: 0, messages: 0);
    }
  } else {
    return const ConvertResult(jsonl: '', conversations: 0, messages: 0);
  }

  final rawMsgs = <Map<String, dynamic>>[];
  for (final it in items) {
    if (it is Map) {
      final norm = _normalizeKeys(it);
      if (_isMessageLike(norm)) rawMsgs.add(norm);
    }
  }
  if (rawMsgs.isEmpty) {
    return const ConvertResult(jsonl: '', conversations: 0, messages: 0);
  }

  // 按会话分组；无 conversationId 则归入单一会话。
  final byConv = <String, List<Map<String, dynamic>>>{};
  for (final m in rawMsgs) {
    final cid = _pick(_convKeys, m);
    byConv.putIfAbsent(cid, () => []).add(m);
  }

  final lines = <String>[];
  for (final entry in byConv.entries) {
    final msgs = entry.value;
    // 会话类型按「文件内作者数」判断（me 是并入的登录用户，不算第三方聊天的参与人）。
    final fileSenders = <String>{
      for (final m in msgs)
        if (_pick(_senderKeys, m).isNotEmpty) _pick(_senderKeys, m),
    };
    final senders = {...fileSenders};
    if (me != null) senders.add(me);
    final participants = senders.toList();
    final firstAt = msgs
            .map((m) => _toEpochMs(_pickValue(_timeKeys, m)))
            .where((t) => t > 0)
            .fold<int?>(
              null,
              (a, t) => a == null ? t : (t < a ? t : a),
            ) ??
        DateTime.now().millisecondsSinceEpoch;
    final id = entry.key.isNotEmpty
        ? entry.key
        : deterministicConversationId(participants, firstAt);
    final type = fileSenders.length > 2 ? 'group' : 'direct';
    lines.add(jsonEncode({
      'record': 'conversation',
      'id': id,
      'type': type,
      'name': type == 'group' ? fileSenders.join(', ') : null,
      'participants': participants,
      'createdAt': firstAt,
    }));
    for (final m in msgs) {
      lines.add(_messageLine(
        conversationId: id,
        senderId: _pick(_senderKeys, m).isEmpty
            ? 'unknown'
            : _pick(_senderKeys, m),
        content: _pick(_contentKeys, m),
        type: _mapType(_pick(_typeKeys, m)),
        createdAt: _toEpochMs(_pickValue(_timeKeys, m)),
        metadata: _pickValue(_metaKeys, m),
      ));
    }
  }
  return ConvertResult(
    jsonl: lines.isEmpty ? '' : '${lines.join('\n')}\n',
    conversations: byConv.length,
    messages: rawMsgs.length,
  );
}

bool _isMessageLike(Map<String, dynamic> m) {
  final hasContent = _contentKeys.any((k) =>
      m[k] != null && m[k].toString().isNotEmpty);
  final hasTime = _timeKeys.any((k) => m[k] != null);
  return hasContent || hasTime;
}

// ---- txt 逐行解析 ----

/// 时间在前的行：`2024-01-01 12:30:00 张三: 你好` / `[2024/1/1 9:5] 张三`。
final RegExp _tsRe = RegExp(
  r'^\[?(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?\]?\s*(.*)$',
);

/// 发送者在前的行：`张三 2024-01-01 12:30:00`（内容在后续行）。
final RegExp _authorFirstRe = RegExp(
  r'^(.+?)\s+(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?\s*$',
);

ConvertResult _convertTxt(String text, {String? me}) {
  final messages = <({String author, int time, String content})>[];
  String? curAuthor;
  var curTime = 0;
  final curContent = StringBuffer();

  void flush() {
    if (curAuthor != null && curContent.isNotEmpty) {
      messages.add(
          (author: curAuthor!, time: curTime, content: curContent.toString()));
    }
    curAuthor = null;
    curTime = 0;
    curContent.clear();
  }

  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;

    final tm = _tsRe.firstMatch(t);
    if (tm != null) {
      flush();
      curTime = _makeTime(
        int.parse(tm[1]!),
        int.parse(tm[2]!),
        int.parse(tm[3]!),
        int.parse(tm[4]!),
        int.parse(tm[5]!),
        tm[6] == null ? 0 : int.parse(tm[6]!),
      );
      final parsed = _parseTxtRest(tm[7] ?? '');
      curAuthor = parsed.author;
      if (parsed.content != null) curContent.write(parsed.content);
      continue;
    }

    final af = _authorFirstRe.firstMatch(t);
    if (af != null) {
      flush();
      curAuthor = af[1]!.trim();
      curTime = _makeTime(
        int.parse(af[2]!),
        int.parse(af[3]!),
        int.parse(af[4]!),
        int.parse(af[5]!),
        int.parse(af[6]!),
        af[7] == null ? 0 : int.parse(af[7]!),
      );
      continue;
    }

    // 普通内容行：折叠进上一条（若当前没有作者，可能是文件头，忽略）。
    if (curAuthor != null) {
      if (curContent.isNotEmpty) curContent.write('\n');
      curContent.write(t);
    }
  }
  flush();

  // 空内容消息（多为纯文件头/无效行）丢弃。
  messages.removeWhere((m) => m.content.trim().isEmpty);
  if (messages.isEmpty) {
    return const ConvertResult(jsonl: '', conversations: 0, messages: 0);
  }

  // 会话类型按「文件内作者数」判断（me 是并入的登录用户，不算第三方聊天的参与人）。
  final fileSenders = <String>{for (final m in messages) m.author};
  final senders = {...fileSenders};
  if (me != null) senders.add(me);
  final participants = senders.toList();
  final firstAt =
      messages.map((m) => m.time).reduce((a, b) => a < b ? a : b);
  final convId = deterministicConversationId(participants, firstAt);
  final type = fileSenders.length > 2 ? 'group' : 'direct';

  final lines = <String>[
    jsonEncode({
      'record': 'conversation',
      'id': convId,
      'type': type,
      'name': type == 'group' ? fileSenders.join(', ') : null,
      'participants': participants,
      'createdAt': firstAt,
    }),
  ];
  for (final m in messages) {
    lines.add(_messageLine(
      conversationId: convId,
      senderId: m.author,
      content: m.content,
      type: 'text',
      createdAt: m.time,
      metadata: null,
    ));
  }
  return ConvertResult(
    jsonl: '${lines.join('\n')}\n',
    conversations: 1,
    messages: messages.length,
  );
}

/// 解析时间戳行剩余部分：`张三: 你好` / `张三(wxid) 你好` / `张三`（内容在后续行）。
({String author, String? content}) _parseTxtRest(String rest) {
  final colon = RegExp(r'^([^:：]+)[:：]\s?(.*)$').firstMatch(rest);
  if (colon != null) {
    final content = colon[2] ?? '';
    return (
      author: colon[1]!.trim().isEmpty ? 'unknown' : colon[1]!.trim(),
      content: content.isEmpty ? null : content,
    );
  }
  final paren = RegExp(r'^([^()]+)\(([^)]*)\)\s*(.*)$').firstMatch(rest);
  if (paren != null) {
    final content = paren[3] ?? '';
    return (
      author: paren[1]!.trim().isEmpty ? 'unknown' : paren[1]!.trim(),
      content: content.isEmpty ? null : content,
    );
  }
  return (author: rest.trim().isEmpty ? 'unknown' : rest.trim(), content: null);
}

int _makeTime(int y, int mo, int d, int h, int mi, int s) =>
    DateTime(y, mo, d, h, mi, s).millisecondsSinceEpoch;

// ---- 通用 ----

String _mapType(Object? t) {
  final s = (t ?? '').toString().toLowerCase();
  if (s.contains('image') ||
      s.contains('picture') ||
      s.contains('photo') ||
      s == 'img') {
    return 'image';
  }
  if (s.contains('file') ||
      s.contains('video') ||
      s.contains('audio') ||
      s.contains('voice') ||
      s.contains('emoji')) {
    return 'file';
  }
  if (s.contains('system') || s == 'notice' || s == 'notification') {
    return 'system';
  }
  return 'text';
}

int _toEpochMs(Object? v) {
  if (v == null) return 0;
  if (v is num) {
    if (v >= 1e12) return v.toInt(); // 毫秒
    if (v >= 1e9) return (v * 1000).round(); // 秒
    return v.toInt();
  }
  final s = v.toString().trim();
  if (s.isEmpty) return 0;
  return _parseTime(s)?.millisecondsSinceEpoch ?? 0;
}

DateTime? _parseTime(String s) {
  final m = RegExp(
    r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$',
  ).firstMatch(s);
  if (m == null) return null;
  return DateTime(
    int.parse(m[1]!),
    int.parse(m[2]!),
    int.parse(m[3]!),
    m[4] == null ? 0 : int.parse(m[4]!),
    m[5] == null ? 0 : int.parse(m[5]!),
    m[6] == null ? 0 : int.parse(m[6]!),
  );
}

/// 生成一条本格式 message 行（确定性 id，重复导入幂等）。
String _messageLine({
  required String conversationId,
  required String senderId,
  required String content,
  required String type,
  required int createdAt,
  Object? metadata,
}) {
  return jsonEncode({
    'record': 'message',
    'id': deterministicId(conversationId, senderId, content, createdAt),
    'conversationId': conversationId,
    'senderId': senderId,
    'type': type,
    'content': content,
    'createdAt': createdAt,
    'editedAt': null,
    'metadata': metadata is Map ? metadata : const <String, dynamic>{},
  });
}
