import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../state.dart';
import 'export_filter_sheet.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(chatServiceProvider)?.syncOnce();
      if (!context.mounted) return;
      _toast(context, '同步完成');
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '同步失败：$e');
    }
  }

  /// 弹出导出过滤条件；用户取消返回 null。
  Future<ExportFilter?> _pickFilter(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final service = ref.read(chatServiceProvider);
    if (service == null) return null;
    final convs = await ref.read(databaseProvider).getAllConversations();
    if (!context.mounted) return null;
    return showExportFilterSheet(
      context,
      currentUser: service.username,
      conversations: convs,
    );
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final service = ref.read(chatServiceProvider);
    if (service == null) return;
    final filter = await _pickFilter(context, ref);
    if (filter == null || !context.mounted) return; // 用户取消
    try {
      final text = await service.exportLocalJsonl(
        conversationId: filter.conversationId,
        senderId: filter.senderId,
        from: filter.from,
        to: filter.to,
      );
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/chat_export_${DateTime.now().millisecondsSinceEpoch}.jsonl',
      );
      await file.writeAsString(text);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: '聊天记录导出'),
      );
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '导出失败：$e');
    }
  }

  Future<void> _exportServer(BuildContext context, WidgetRef ref) async {
    final service = ref.read(chatServiceProvider);
    if (service == null) return;
    final filter = await _pickFilter(context, ref);
    if (filter == null || !context.mounted) return; // 用户取消
    try {
      final text = await service.exportFromServer(
        conversationId: filter.conversationId,
        senderId: filter.senderId,
        from: filter.from,
        to: filter.to,
      );
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/chat_server_export_${DateTime.now().millisecondsSinceEpoch}.jsonl',
      );
      await file.writeAsString(text);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: '服务器聊天记录导出'),
      );
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '导出失败：$e');
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final service = ref.read(chatServiceProvider);
    if (service == null) return;
    try {
      final result = await FilePicker.platform.pickFiles();
      final path = result?.files.single.path;
      if (path == null) return;
      final text = await File(path).readAsString();
      final r = await service.importLocalJsonl(text);
      if (!context.mounted) return;
      _toast(context, '导入完成：${r.conversations} 个会话，${r.messages} 条消息');
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '导入失败：$e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authControllerProvider).session;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.person),
            title: Text(session?.username ?? ''),
            subtitle: Text(session?.serverUrl ?? ''),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('立即同步'),
            onTap: () => _sync(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.upload),
            title: const Text('导出聊天记录（本地 JSONL）'),
            onTap: () => _export(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('导入聊天记录（合并去重）'),
            onTap: () => _import(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_download),
            title: const Text('从服务器导出全量'),
            onTap: () => _exportServer(context, ref),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('退出登录'),
            onTap: () => ref.read(authControllerProvider.notifier).logout(),
          ),
        ],
      ),
    );
  }
}
