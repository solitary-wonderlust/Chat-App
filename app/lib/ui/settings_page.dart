import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../import_export/jsonl.dart';
import '../state.dart';
import 'export_filter_sheet.dart';
import 'import_preview.dart';

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

  /// 运行期间展示不可取消的「处理中」弹窗。
  Future<T> _withProgress<T>(BuildContext context, Future<T> Function() action) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('处理中…'),
            ],
          ),
        ),
      ),
    );
    try {
      return await action();
    } finally {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  /// 选择并读取聊天记录文件，统一转成本格式 JSONL（本格式透传，微信/QQ txt 或常见 json 自动转换）。
  /// 返回 null 表示用户取消或文件无法识别。
  Future<String?> _pickImportJsonl(BuildContext context, WidgetRef ref) async {
    final service = ref.read(chatServiceProvider);
    if (service == null) return null;
    final result = await FilePicker.platform.pickFiles();
    final path = result?.files.single.path;
    if (path == null) return null;
    final text = await File(path).readAsString();
    final converted = service.convertImportText(text);
    if (converted.isEmpty) {
      if (!context.mounted) return null;
      _toast(context, '无法识别文件格式（支持本格式 JSONL 或微信/QQ 导出的 txt/json）');
      return null;
    }
    return converted.jsonl;
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
      final text = await _withProgress(
        context,
        () => service.exportFromServer(
          conversationId: filter.conversationId,
          senderId: filter.senderId,
          from: filter.from,
          to: filter.to,
        ),
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

  /// 本地导入：预览差异 → 让用户选「跳过已有 / 覆盖已有」→ 按选择导入。
  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final service = ref.read(chatServiceProvider);
    if (service == null) return;
    final jsonl = await _pickImportJsonl(context, ref);
    if (jsonl == null) return;
    if (!context.mounted) return;
    try {
      final preview = await service.previewImportLocal(jsonl);
      if (!context.mounted) return;
      final choice = await showImportPreviewSheet(context, preview);
      if (choice == null) return; // 用户取消
      final r = await service.importLocalJsonl(
        jsonl,
        mode: choice == ImportChoice.overwrite
            ? ImportMode.overwrite
            : ImportMode.skipExisting,
      );
      if (!context.mounted) return;
      _toast(context, '导入完成：${r.conversations} 个会话，${r.messages} 条消息');
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '导入失败：$e');
    }
  }

  /// 导入到服务器：把本地文件（JSONL 或微信/QQ txt）上传服务器 /import，跨设备合并。
  Future<void> _importServer(BuildContext context, WidgetRef ref) async {
    final service = ref.read(chatServiceProvider);
    if (service == null) return;
    final jsonl = await _pickImportJsonl(context, ref);
    if (jsonl == null) return;
    if (!context.mounted) return;
    try {
      final r = await _withProgress(
        context,
        () => service.importToServer(jsonl),
      );
      if (!context.mounted) return;
      _toast(context, '已导入到服务器：${r.conversations} 个会话，${r.messages} 条消息');
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '导入到服务器失败：$e');
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
            leading: const Icon(Icons.cloud_upload),
            title: const Text('导入到服务器（跨设备合并）'),
            onTap: () => _importServer(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_download),
            title: const Text('从服务器导出'),
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
