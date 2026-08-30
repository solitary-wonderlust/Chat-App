// REST 客户端：与 server/src/routes.ts 的接口一一对应。

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 按文件名粗略猜 mime；非图片返回 application/octet-stream（服务端也接受）。
String guessMime(String name) {
  final ext = name.split('.').last.toLowerCase();
  const map = <String, String>{
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'bmp': 'image/bmp',
    'heic': 'image/heic',
    'txt': 'text/plain',
    'pdf': 'application/pdf',
    'zip': 'application/zip',
    'mp3': 'audio/mpeg',
    'mp4': 'video/mp4',
  };
  return map[ext] ?? 'application/octet-stream';
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  @override
  String toString() => 'ApiException($statusCode): $body';
}

class ApiClient {
  ApiClient(this.baseUrl, {http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> _auth(String token) =>
      {'authorization': 'Bearer $token'};

  Future<Map<String, dynamic>> register(String username, String password) =>
      _post('/auth/register', {'username': username, 'password': password});

  Future<Map<String, dynamic>> login(String username, String password) =>
      _post('/auth/login', {'username': username, 'password': password});

  Future<List<dynamic>> listConversations(String token) =>
      _getList('/conversations', token);

  Future<List<dynamic>> listMessages(
    String token,
    String conversationId, {
    int after = 0,
  }) =>
      _getList(
        '/messages?conversationId=$conversationId&after=$after',
        token,
      );

  Future<Map<String, dynamic>> createConversation(
    String token,
    List<String> participants, {
    String type = 'direct',
    String? name,
  }) =>
      _post(
        '/conversations',
        {'participants': participants, 'type': type, 'name': name},
        token,
      );

  Future<Map<String, dynamic>> sendMessage(
    String token,
    Map<String, dynamic> message,
  ) =>
      _post('/messages', message, token);

  /// 编辑消息（仅发送者 + text 类型，见 docs/api.md §编辑/撤回）。
  Future<Map<String, dynamic>> updateMessage(
    String token,
    String id,
    String content,
  ) =>
      _patch('/messages/$id', {'content': content}, token);

  /// 撤回消息（软删墓碑：content 清空 + metadata.deleted）。
  Future<Map<String, dynamic>> deleteMessage(String token, String id) async {
    final res = await _client.delete(_u('/messages/$id'), headers: _auth(token));
    _ensure(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// 上报当前用户在会话的已读游标。
  Future<Map<String, dynamic>> markRead(
    String token,
    String conversationId,
    int upTo,
  ) =>
      _post('/conversations/$conversationId/read', {'upTo': upTo}, token);

  /// 某会话所有参与者的已读游标。
  Future<List<dynamic>> conversationReads(String token, String conversationId) =>
      _getList('/conversations/$conversationId/read', token);

  /// 按关键词搜消息（只搜当前用户参与的会话，见 docs/api.md §搜索）。
  Future<List<dynamic>> searchMessages(
    String token, {
    required String query,
    String? conversationId,
  }) {
    final qs = StringBuffer('/search?q=${Uri.encodeQueryComponent(query)}');
    if (conversationId != null) qs.write('&conversationId=$conversationId');
    return _getList(qs.toString(), token);
  }

  /// 导出 JSONL，可按 会话/发送者/时间范围 过滤。
  Future<String> export(
    String token, {
    String? conversationId,
    String? senderId,
    int? from,
    int? to,
  }) async {
    final params = <String, String>{};
    if (conversationId != null) params['conversationId'] = conversationId;
    if (senderId != null) params['senderId'] = senderId;
    if (from != null) params['from'] = '$from';
    if (to != null) params['to'] = '$to';
    final qs = params.isEmpty ? '' : '?${Uri(queryParameters: params).query}';
    final res = await _client.get(_u('/export$qs'), headers: _auth(token));
    _ensure(res);
    return res.body;
  }

  Future<Map<String, dynamic>> import(String token, String text) =>
      _post('/import', {'text': text}, token);

  /// 上传附件（原始字节）。响应里 url 是服务器相对路径，作消息 content 用。
  Future<Map<String, dynamic>> uploadAttachment(
    String token,
    Uint8List bytes,
    String filename,
    String mime,
  ) async {
    final headers = _auth(token)
      ..['content-type'] = mime
      ..['x-filename'] = Uri.encodeComponent(filename);
    final res = await _client.post(
      _u('/attachments'),
      headers: headers,
      body: bytes,
    );
    _ensure(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, [
    String? token,
  ]) async {
    final headers = {'content-type': 'application/json'};
    if (token != null) headers.addAll(_auth(token));
    final res = await _client.post(_u(path), headers: headers, body: jsonEncode(body));
    _ensure(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _patch(
    String path,
    Map<String, dynamic> body,
    String token,
  ) async {
    final headers = {'content-type': 'application/json'}..addAll(_auth(token));
    final res = await _client.patch(_u(path), headers: headers, body: jsonEncode(body));
    _ensure(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> _getList(String path, String token) async {
    final res = await _client.get(_u(path), headers: _auth(token));
    _ensure(res);
    return jsonDecode(res.body) as List<dynamic>;
  }

  void _ensure(http.Response res) {
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
  }
}
