// 聊天核心服务：把 DB / API / 实时同步 / 导入导出串起来。

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'api/api_client.dart';
import 'auth/session.dart';
import 'db/database.dart';
import 'import_export/jsonl.dart';

class ChatService {
  ChatService({required this.db, required this.api, required this.session});

  final AppDatabase db;
  final ApiClient api;
  final Session session;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  bool _closed = false;

  String get _token => session.token;
  String get username => session.username;

  // ---- 实时连接 ----

  void connect() {
    final base = api.baseUrl;
    final wsBase = base.startsWith('https://')
        ? base.replaceFirst('https', 'wss')
        : base.replaceFirst('http', 'ws');
    _channel = WebSocketChannel.connect(Uri.parse('$wsBase/ws?token=$_token'));
    _sub = _channel!.stream.listen(
      _onEvent,
      onDone: _reconnect,
      onError: (_) => _reconnect(),
    );
  }

  void _reconnect() {
    _sub?.cancel();
    if (_closed) return;
    Future.delayed(const Duration(seconds: 3), connect);
  }

  void dispose() {
    _closed = true;
    _sub?.cancel();
    _channel?.sink.close();
  }

  void _onEvent(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      final event = data['event'] as String?;
      final payload = data['data'] as Map<String, dynamic>?;
      if (payload == null) return;
      if (event == 'message') {
        unawaited(db.upsertMessage(messageCompanion(payload)));
      } else if (event == 'conversation') {
        unawaited(db.upsertConversation(conversationCompanion(payload)));
      }
    } catch (_) {
      // 忽略无法解析的帧
    }
  }

  // ---- 发送（离线优先） ----

  Future<void> sendMessage(
    String conversationId,
    String content, {
    String type = 'text',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final record = <String, dynamic>{
      'record': 'message',
      'id': newId(),
      'conversationId': conversationId,
      'senderId': username,
      'type': type,
      'content': content,
      'createdAt': now,
      'editedAt': null,
      'metadata': <String, dynamic>{},
    };
    // 先落本地（离线可用），再入 outbox，最后尝试立即推送。
    await db.upsertMessage(messageCompanion(record));
    await db.enqueueOutbox(OutboxCompanion.insert(
      id: record['id'] as String,
      payload: jsonEncode(record),
      createdAt: now,
    ));
    unawaited(pushOutbox());
  }

  Future<void> createConversation(
    List<String> participants, {
    String type = 'direct',
    String? name,
  }) async {
    final res = await api.createConversation(
      _token,
      participants,
      type: type,
      name: name,
    );
    await db.upsertConversation(conversationCompanion(res));
  }

  // ---- 同步 ----

  Future<void> syncOnce() async {
    await pushOutbox();
    await pullAll();
  }

  /// 把 outbox 里待发送的消息推给服务器，成功一条删一条；失败（离线）则中断留待下次。
  Future<void> pushOutbox() async {
    final pending = await db.pendingOutbox();
    for (final o in pending) {
      try {
        await api.sendMessage(
          _token,
          jsonDecode(o.payload) as Map<String, dynamic>,
        );
        await db.removeOutbox(o.id);
      } catch (_) {
        break;
      }
    }
  }

  /// 拉会话列表 + 逐个会话增量拉消息（游标 = 本地最大 created_at）。
  Future<void> pullAll() async {
    try {
      final convs = await api.listConversations(_token);
      for (final c in convs) {
        await db.upsertConversation(conversationCompanion(c as Map<String, dynamic>));
      }
    } catch (_) {}
    for (final id in await db.allConversationIds()) {
      try {
        final after = await db.maxMessageCreatedAt(id);
        final msgs = await api.listMessages(_token, id, after: after);
        for (final m in msgs) {
          await db.upsertMessage(messageCompanion(m as Map<String, dynamic>));
        }
      } catch (_) {}
    }
  }

  // ---- 导入 / 导出 ----

  Future<String> exportLocalJsonl({String? conversationId}) =>
      exportJsonl(db, conversationId: conversationId);

  Future<ImportResult> importLocalJsonl(String text) => importJsonl(db, text);

  /// 从服务器全量导出（客户端本地可能不完整时用它兜底）。
  Future<String> exportFromServer() => api.export(_token);

  /// 把 JSONL 推给服务器导入（跨设备合并）。
  Future<ImportResult> importToServer(String text) async {
    final res = await api.import(_token, text);
    return (
      conversations: res['conversations'] as int? ?? 0,
      messages: res['messages'] as int? ?? 0,
    );
  }
}
