// REST 客户端：与 server/src/routes.ts 的接口一一对应。

import 'dart:convert';

import 'package:http/http.dart' as http;

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

  Future<String> export(String token) async {
    final res = await _client.get(_u('/export'), headers: _auth(token));
    _ensure(res);
    return res.body;
  }

  Future<Map<String, dynamic>> import(String token, String text) =>
      _post('/import', {'text': text}, token);

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

  Future<List<dynamic>> _getList(String path, String token) async {
    final res = await _client.get(_u(path), headers: _auth(token));
    _ensure(res);
    return jsonDecode(res.body) as List<dynamic>;
  }

  void _ensure(http.Response res) {
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
  }
}
