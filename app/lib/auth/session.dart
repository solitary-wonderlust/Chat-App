// 登录态：token / 用户 / 服务器地址的持久化。

import 'package:shared_preferences/shared_preferences.dart';

class Session {
  const Session({
    required this.token,
    required this.userId,
    required this.username,
    required this.serverUrl,
  });

  final String token;
  final String userId;
  final String username;
  final String serverUrl;
}

class SessionStore {
  static const _kToken = 'token';
  static const _kUserId = 'userId';
  static const _kUsername = 'username';
  static const _kServer = 'serverUrl';

  Future<void> save(Session s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kToken, s.token);
    await p.setString(_kUserId, s.userId);
    await p.setString(_kUsername, s.username);
    await p.setString(_kServer, s.serverUrl);
  }

  Future<Session?> load() async {
    final p = await SharedPreferences.getInstance();
    final token = p.getString(_kToken);
    final userId = p.getString(_kUserId);
    final username = p.getString(_kUsername);
    final serverUrl = p.getString(_kServer);
    if (token == null || userId == null || username == null || serverUrl == null) {
      return null;
    }
    return Session(
      token: token,
      userId: userId,
      username: username,
      serverUrl: serverUrl,
    );
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kToken);
    await p.remove(_kUserId);
    await p.remove(_kUsername);
    // 保留 serverUrl，方便下次登录直接用。
  }
}
