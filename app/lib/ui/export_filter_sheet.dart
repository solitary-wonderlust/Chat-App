// 导出过滤条件选择 sheet：按 会话 / 发送者 / 时间范围 过滤导出内容。

import 'dart:convert';

import 'package:flutter/material.dart';

import '../db/database.dart';

/// 导出过滤条件。全部可空：null 表示不过滤。
class ExportFilter {
  const ExportFilter({
    this.conversationId,
    this.senderId,
    this.from,
    this.to,
  });

  final String? conversationId;
  final String? senderId;

  /// created_at >= from（epoch 毫秒）。
  final int? from;

  /// created_at <= to（epoch 毫秒）。
  final int? to;
}

Future<ExportFilter?> showExportFilterSheet(
  BuildContext context, {
  required String currentUser,
  required List<Conversation> conversations,
}) {
  return showModalBottomSheet<ExportFilter>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ExportFilterSheet(
      currentUser: currentUser,
      conversations: conversations,
    ),
  );
}

class ExportFilterSheet extends StatefulWidget {
  const ExportFilterSheet({
    super.key,
    required this.currentUser,
    required this.conversations,
  });

  final String currentUser;
  final List<Conversation> conversations;

  @override
  State<ExportFilterSheet> createState() => _ExportFilterSheetState();
}

class _ExportFilterSheetState extends State<ExportFilterSheet> {
  String? _conversationId;
  final _senderCtrl = TextEditingController();
  DateTime? _from;
  DateTime? _to;

  @override
  void dispose() {
    _senderCtrl.dispose();
    super.dispose();
  }

  String _title(Conversation c) {
    final me = widget.currentUser;
    final others = (jsonDecode(c.participants) as List)
        .cast<String>()
        .where((u) => u != me)
        .toList();
    if (c.type == 'group' && (c.name ?? '').isNotEmpty) return c.name!;
    if (c.type == 'group') return '${others.join(', ')} 的群';
    return others.isEmpty ? '自己' : others.join(', ');
  }

  Future<void> _pickDate({required bool start}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (start ? _from : _to) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    setState(() {
      if (start) {
        _from = DateTime(picked.year, picked.month, picked.day);
      } else {
        _to = DateTime(picked.year, picked.month, picked.day, 23, 59, 59, 999);
      }
    });
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final senderId = _senderCtrl.text.trim();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '导出过滤',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _conversationId,
              decoration: const InputDecoration(
                labelText: '会话',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('全部会话'),
                ),
                for (final c in widget.conversations)
                  DropdownMenuItem<String?>(
                    value: c.id,
                    child: Text(_title(c), overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _conversationId = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _senderCtrl,
              decoration: const InputDecoration(
                labelText: '发送者用户名（可选）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _pickDate(start: true),
                    child: Text(
                      _from == null ? '开始日期（可选）' : '起：${_fmt(_from!)}',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _pickDate(start: false),
                    child: Text(
                      _to == null ? '结束日期（可选）' : '止：${_fmt(_to!)}',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                ExportFilter(
                  conversationId: _conversationId,
                  senderId: senderId.isEmpty ? null : senderId,
                  from: _from?.millisecondsSinceEpoch,
                  to: _to?.millisecondsSinceEpoch,
                ),
              ),
              child: const Text('确定并导出'),
            ),
          ],
        ),
      ),
    );
  }
}
