// 导入前预览与冲突选择 sheet：展示「新增 / 覆盖（内容不同）/ 相同」差异，
// 让用户选择「跳过已有」或「覆盖已有」。取消返回 null。

import 'package:flutter/material.dart';

import '../import_export/jsonl.dart';

/// 用户选择的导入方式；返回 null 表示取消。
enum ImportChoice { skipExisting, overwrite }

/// 弹出导入预览 sheet；返回用户选择（取消为 null）。
Future<ImportChoice?> showImportPreviewSheet(
  BuildContext context,
  ImportPreview preview,
) {
  return showModalBottomSheet<ImportChoice>(
    context: context,
    builder: (_) => ImportPreviewSheet(preview: preview),
  );
}

class ImportPreviewSheet extends StatelessWidget {
  const ImportPreviewSheet({super.key, required this.preview});

  final ImportPreview preview;

  @override
  Widget build(BuildContext context) {
    final noChange = !preview.hasChanges;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '导入预览',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '将写入本地聊天记录（合并去重）。已存在的记录按你的选择跳过或覆盖。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _Row(label: '新增会话', value: preview.newConversations),
            _Row(label: '已存在会话', value: preview.existingConversations),
            _Row(label: '新增消息', value: preview.newMessages),
            _Row(label: '已存在消息（内容不同）', value: preview.changedMessages),
            _Row(label: '已存在消息（相同）', value: preview.identicalMessages),
            const SizedBox(height: 16),
            if (noChange)
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('内容已是最新，无需导入'),
              )
            else ...[
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, ImportChoice.skipExisting),
                child: const Text('跳过已有（只导入新增）'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () =>
                    Navigator.pop(context, ImportChoice.overwrite),
                child: const Text('覆盖已有（完整合并）'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(
              '$value',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
}
