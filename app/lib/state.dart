// Riverpod 依赖注入与登录态管理。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'auth/session.dart';
import 'db/database.dart';
import 'service.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() => db.close());
  return db;
});

final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore());

class AuthState {
  const AuthState({this.session, this.loading = true});
  final Session? session;
  final bool loading;
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) {
  return AuthController(ref.read(sessionStoreProvider));
});

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._store) : super(const AuthState()) {
    _restore();
  }

  final SessionStore _store;

  Future<void> _restore() async {
    final s = await _store.load();
    state = AuthState(session: s, loading: false);
  }

  Future<void> login(String serverUrl, String username, String password) async {
    final api = ApiClient(_normalize(serverUrl));
    final res = await api.login(username, password);
    final session = Session(
      token: res['token'] as String,
      userId: res['userId'] as String,
      username: res['username'] as String,
      serverUrl: _normalize(serverUrl),
    );
    await _store.save(session);
    state = AuthState(session: session, loading: false);
  }

  Future<void> register(
    String serverUrl,
    String username,
    String password,
  ) async {
    final api = ApiClient(_normalize(serverUrl));
    final res = await api.register(username, password);
    final session = Session(
      token: res['token'] as String,
      userId: res['userId'] as String,
      username: res['username'] as String,
      serverUrl: _normalize(serverUrl),
    );
    await _store.save(session);
    state = AuthState(session: session, loading: false);
  }

  Future<void> logout() async {
    await _store.clear();
    state = const AuthState(session: null, loading: false);
  }
}

/// 登录后按当前 session 提供 ChatService；未登录返回 null。
final chatServiceProvider = Provider<ChatService?>((ref) {
  final session = ref.watch(authControllerProvider).session;
  if (session == null) return null;
  final db = ref.watch(databaseProvider);
  final service = ChatService(
    db: db,
    api: ApiClient(session.serverUrl),
    session: session,
  );
  ref.onDispose(service.dispose);
  return service;
});

String _normalize(String url) {
  var u = url.trim();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  return u;
}
