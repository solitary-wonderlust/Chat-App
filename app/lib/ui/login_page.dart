import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  // Android 模拟器访问宿主机用 10.0.2.2；iOS 模拟器用 localhost；真机用电脑局域网 IP。
  final _server = TextEditingController(text: 'http://192.168.1.20:3000');
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;

  Future<void> _submit({required bool register}) async {
    setState(() => _busy = true);
    try {
      final ctrl = ref.read(authControllerProvider.notifier);
      final username = _user.text.trim();
      final password = _pass.text;
      if (username.isEmpty || password.isEmpty) {
        throw Exception('用户名和密码不能为空');
      }
      if (register) {
        await ctrl.register(_server.text, username, password);
      } else {
        await ctrl.login(_server.text, username, password);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Chat', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 24),
                TextField(
                  controller: _server,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _user,
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : () => _submit(register: false),
                  child: const Text('登录'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _busy ? null : () => _submit(register: true),
                  child: const Text('注册'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
