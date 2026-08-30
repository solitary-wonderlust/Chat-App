// 消息搜索页：输入关键词，服务端搜索（只搜当前用户参与的会话），点击结果跳转会话。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import 'chat_page.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _results = [];
  Map<String, String> _convTitles = {};
  bool _loading = false;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    _loadTitles();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _loadTitles() async {
    final service = ref.read(chatServiceProvider);
    if (service == null) return;
    final convs = await ref.read(databaseProvider).getAllConversations();
    final me = service.username;
    final titles = <String, String>{};
    for (final c in convs) {
      final others = (jsonDecode(c.participants) as List)
          .cast<String>()
          .where((u) => u != me)
          .toList();
      if (c.type == 'group' && (c.name ?? '').isNotEmpty) {
        titles[c.id] = c.name!;
      } else if (c.type == 'group') {
        titles[c.id] = '${others.join(', ')} 的群';
      } else {
        titles[c.id] = others.isEmpty ? '自己' : others.join(', ');
      }
    }
    if (mounted) setState(() => _convTitles = titles);
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    final query = q.trim();
    if (query.isEmpty) {
      setState(() {
        _results = [];
        _searched = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(query));
  }

  Future<void> _search(String query) async {
    final service = ref.read(chatServiceProvider);
    if (service == null) return;
    setState(() => _loading = true);
    try {
      final rows = await service.searchMessages(query);
      if (!mounted) return;
      setState(() {
        _results = rows.cast<Map<String, dynamic>>();
        _searched = true;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('搜索失败（需联网）：$e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _time(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${dt.month}-${dt.day} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _q,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '搜索消息…',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _results.isEmpty
              ? Center(
                  child: Text(_searched ? '无匹配结果' : '输入关键词搜索消息'),
                )
              : ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (ctx, i) {
                    final m = _results[i];
                    final convId = (m['conversationId'] ?? '').toString();
                    return ListTile(
                      leading: const Icon(Icons.chat_bubble_outline),
                      title: Text(
                        (m['content'] ?? '').toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${_convTitles[convId] ?? '会话'} · ${m['senderId']} · '
                        '${_time((m['createdAt'] as num?)?.toInt() ?? 0)}',
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ChatPage(conversationId: convId),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
