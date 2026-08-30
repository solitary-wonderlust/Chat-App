import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api/api_client.dart';
import '../db/database.dart';
import '../state.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _picker = ImagePicker();
  StreamSubscription<List<Message>>? _sub;
  StreamSubscription<Map<String, dynamic>>? _readSub;
  List<Message> _msgs = [];
  bool _sending = false;

  // 已读回执显示：direct 会话里对方已读到的最大 created_at。
  int _otherReadUpTo = 0;
  bool _isGroup = false;

  @override
  void initState() {
    super.initState();
    _sub = ref
        .read(databaseProvider)
        .watchMessages(widget.conversationId)
        .listen((rows) {
      if (mounted) setState(() => _msgs = rows);
      unawaited(_markRead());
    });
    _refreshConversation();
    // 订阅服务端推送的已读回执，实时刷新「已读/未读」。
    _readSub = ref.read(chatServiceProvider)?.readEvents.listen((payload) {
      if (payload['conversationId'] != widget.conversationId) return;
      final user = payload['username'];
      if (user == null || user == ref.read(chatServiceProvider)?.username) return;
      if (mounted) setState(() => _otherReadUpTo = (payload['upTo'] as num?)?.toInt() ?? 0);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _readSub?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _refreshConversation() async {
    final conv = await ref
        .read(databaseProvider)
        .getConversation(widget.conversationId);
    if (!mounted || conv == null) return;
    setState(() => _isGroup = conv.type == 'group');
    await _markRead();
  }

  /// 上报已读游标 + 拉取对方游标（离线静默失败）。
  Future<void> _markRead() async {
    await ref
        .read(chatServiceProvider)
        ?.markConversationRead(widget.conversationId);
    try {
      final reads = await ref
          .read(chatServiceProvider)!
          .conversationReads(widget.conversationId);
      if (!mounted) return;
      final me = ref.read(chatServiceProvider)?.username ?? '';
      reads.forEach((user, upTo) {
        if (user != me) setState(() => _otherReadUpTo = upTo);
      });
    } catch (_) {
      // 拉不到（离线/服务不可用）保持现状。
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await ref.read(chatServiceProvider)?.sendMessage(widget.conversationId, text);
  }

  void _showAttachmentSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('相册'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text('文件'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 88,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      await _sendAttachment(bytes, picked.name, guessMime(picked.name));
    } catch (e) {
      _toast('选择图片失败：$e');
    }
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      final f = result?.files.single;
      final path = f?.path;
      if (f == null || path == null) return;
      final bytes = await File(path).readAsBytes();
      await _sendAttachment(bytes, f.name, guessMime(f.name));
    } catch (e) {
      _toast('选择文件失败：$e');
    }
  }

  /// 上传 + 发送。附件须联网；上传失败给用户报错，不产生本地消息。
  Future<void> _sendAttachment(Uint8List bytes, String name, String mime) async {
    setState(() => _sending = true);
    try {
      await ref
          .read(chatServiceProvider)
          ?.sendAttachment(widget.conversationId, bytes, name, mime);
    } catch (e) {
      if (mounted) _toast('发送附件失败（需联网）：$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 长按自己的消息：编辑 / 撤回。
  void _onBubbleLongPress(Message m) {
    if (_isDeleted(m)) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('编辑'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _editMessage(m);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('撤回'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _withdrawMessage(m);
              },
            ),
          ],
        ),
      ),
    );
  }

  bool _isDeleted(Message m) {
    try {
      return (jsonDecode(m.metadata) as Map)['deleted'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _editMessage(Message m) async {
    final controller = TextEditingController(text: m.content);
    final newContent = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑消息'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '内容'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = newContent?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == m.content) return;
    try {
      await ref
          .read(chatServiceProvider)
          ?.editMessage(widget.conversationId, m.id, trimmed);
    } catch (e) {
      if (mounted) _toast('编辑失败（需联网）：$e');
    }
  }

  Future<void> _withdrawMessage(Message m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤回消息？'),
        content: const Text('撤回后双方都会看到「已撤回」，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('撤回'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(chatServiceProvider)
          ?.deleteMessage(widget.conversationId, m.id);
    } catch (e) {
      if (mounted) _toast('撤回失败（需联网）：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(chatServiceProvider)?.username ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('聊天')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: _msgs.length,
              itemBuilder: (ctx, i) {
                final m = _msgs[_msgs.length - 1 - i];
                final mine = m.senderId == me;
                return GestureDetector(
                  onLongPress: mine ? () => _onBubbleLongPress(m) : null,
                  child: _MessageBubble(
                    message: m,
                    mine: mine,
                    isDirect: !_isGroup,
                    readUpTo: _otherReadUpTo,
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _sending ? null : _showAttachmentSheet,
                    tooltip: '附件',
                    icon: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.attach_file),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      decoration: const InputDecoration(
                        hintText: '输入消息…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条消息气泡：按 type 分支渲染（text / image / file）；已撤回显示占位。
class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    this.isDirect = false,
    this.readUpTo = 0,
  });

  final Message message;
  final bool mine;

  /// direct 会话才显示「已读/未读」；群聊不显示。
  final bool isDirect;

  /// 对方已读游标（direct 会话），用于标记我发的消息是否已被读。
  final int readUpTo;

  Map<String, dynamic> _meta() {
    try {
      return jsonDecode(message.metadata) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  bool get _deleted => _meta()['deleted'] == true;

  Future<void> _openFile(BuildContext context, String baseUrl, String token) async {
    try {
      final res = await http.get(
        Uri.parse('$baseUrl${message.content}'),
        headers: {'authorization': 'Bearer $token'},
      );
      if (res.statusCode != 200) throw Exception('下载失败（${res.statusCode}）');
      final name =
          _meta()['name']?.toString() ?? 'file_${DateTime.now().millisecondsSinceEpoch}';
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(res.bodyBytes);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开附件失败：$e')),
        );
      }
    }
  }

  Widget _content(BuildContext context, WidgetRef ref) {
    final service = ref.read(chatServiceProvider);
    final token = service?.session.token ?? '';
    final baseUrl = service?.api.baseUrl ?? '';
    final textColor = mine ? Colors.white : Colors.black87;

    // 已撤回：不渲染原内容（附件 URL 已清空），显示占位。
    if (_deleted) {
      return Text(
        '已撤回',
        style: TextStyle(
          fontStyle: FontStyle.italic,
          fontSize: 13,
          color: mine ? Colors.white70 : Colors.black45,
        ),
      );
    }

    switch (message.type) {
      case 'image':
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220, maxHeight: 260),
            child: Image.network(
              '$baseUrl${message.content}',
              headers: {'authorization': 'Bearer $token'},
              fit: BoxFit.cover,
              loadingBuilder: (c, child, progress) => progress == null
                  ? child
                  : const SizedBox(
                      width: 160,
                      height: 120,
                      child: Center(child: CircularProgressIndicator()),
                    ),
              errorBuilder: (c, e, s) => const SizedBox(
                width: 160,
                height: 120,
                child: Center(child: Icon(Icons.broken_image, size: 40)),
              ),
            ),
          ),
        );
      case 'file':
        final meta = _meta();
        final name = meta['name']?.toString() ?? '文件';
        final size = meta['size'];
        return InkWell(
          onTap: () => _openFile(context, baseUrl, token),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_drive_file, size: 32, color: textColor),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (size is int)
                    Text(
                      _formatBytes(size),
                      style: TextStyle(
                        fontSize: 11,
                        color: mine ? Colors.white70 : Colors.black54,
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      default:
        return Text(
          message.content,
          style: TextStyle(color: textColor),
        );
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: mine ? Colors.indigo : Colors.grey.shade300,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message.senderId,
              style: TextStyle(
                fontSize: 11,
                color: mine ? Colors.white70 : Colors.black54,
              ),
            ),
            const SizedBox(height: 2),
            _content(context, ref),
            if (mine && isDirect && !_deleted)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  readUpTo >= message.createdAt ? '已读' : '未读',
                  style: TextStyle(
                    fontSize: 10,
                    color: readUpTo >= message.createdAt
                        ? Colors.green.shade200
                        : Colors.white38,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
