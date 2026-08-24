import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../service.dart';
import '../state.dart';
import 'chat_page.dart';
import 'settings_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  StreamSubscription<List<Conversation>>? _sub;
  List<Conversation> _convs = [];
  ChatService? _service;

  @override
  void initState() {
    super.initState();
    final service = ref.read(chatServiceProvider);
    _service = service;
    if (service != null) {
      service.connect();
      service.syncOnce();
      _sub = ref
          .read(databaseProvider)
          .watchConversationsForUser(service.username)
          .listen((rows) {
        if (mounted) setState(() => _convs = rows);
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String _title(Conversation c) {
    final me = _service?.username ?? '';
    if (c.type == 'group' && (c.name ?? '').isNotEmpty) return c.name!;
    final others = (jsonDecode(c.participants) as List)
        .cast<String>()
        .where((u) => u != me)
        .toList();
    if (c.type == 'group') return '${others.join(', ')} 的群';
    return others.isEmpty ? '自己' : others.join(', ');
  }

  Future<void> _newConversation() async {
    final controller = TextEditingController();
    final names = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '对方用户名（群聊用逗号分隔）',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (names == null || names.trim().isEmpty) return;
    final others = names
        .split(RegExp(r'[,，\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    try {
      await _service?.createConversation(
        others,
        type: others.length > 1 ? 'group' : 'direct',
        name: others.length > 1 ? others.join(', ') : null,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('会话'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: _convs.isEmpty
          ? const Center(child: Text('还没有会话，点右下角新建'))
          : ListView.builder(
              itemCount: _convs.length,
              itemBuilder: (ctx, i) {
                final c = _convs[i];
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: Text(_title(c)),
                  subtitle: Text(c.type == 'group' ? '群聊' : '私聊'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatPage(conversationId: c.id),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _newConversation,
        child: const Icon(Icons.add),
      ),
    );
  }
}
