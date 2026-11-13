import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_scope.dart';
import '../core/ai/agent_root.dart';
import '../core/ai/ai_chat.dart';
import '../core/ai/ai_client.dart';
import '../core/ai/web_tools.dart';
import '../core/instance_files.dart';
import 'ai_settings.dart';
import 'file_viewer.dart';

/// 会修改文件的工作区工具：侧边栏「本次对话的文件」从这些调用里收集
const _fileTools = {'ws_write', 'ws_edit', 'ws_move'};

/// 这次对话里 AI 写入、修改、移动过的文件（最近的在前，去重）
List<({String root, String path})> sessionFiles(ChatSession s) {
  final out = <({String root, String path})>[];
  final seen = <String>{};
  for (final m in s.messages.reversed) {
    for (final c in m.toolCalls.reversed) {
      if (!_fileTools.contains(c.name) || s.resultOf(c.id)?.status != ToolStatus.done) continue;
      final root = '${c.args['root'] ?? ''}';
      final path = '${c.name == 'ws_move' ? c.args['to'] : c.args['path']}'.trim();
      if (root.isEmpty || path.isEmpty || !seen.add('$root/$path')) continue;
      out.add((root: root, path: path));
    }
  }
  return out;
}

/// 打开 AI 写的文件；已经不存在时提示
Future<void> openAgentFile(BuildContext context, String root, String path) async {
  final f = await resolveAgentFile(AppScope.read(context), root, path);
  if (!context.mounted) return;
  if (f == null) {
    toast(context, '文件已经不在了：$path');
    return;
  }
  await showFileViewer(context, f);
}

/// AI 页右侧边栏：环境、上下文、本次对话的文件、工作区
class AiSidePanel extends StatelessWidget {
  const AiSidePanel({super.key, required this.chats, required this.session, this.onClose});

  final ChatStore chats;
  final ChatSession? session;
  final VoidCallback? onClose;

  static const width = 296.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = AppScope.of(context);
    final cfg = state.config;
    final ai = AiSettings.load(cfg);
    final s = session;
    final files = s == null ? const <({String root, String path})>[] : sessionFiles(s);
    final busy = s != null && chats.isBusy(s.id);

    Widget row(IconData icon, String text, {String? trailing, VoidCallback? onTap, Color? color}) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color ?? scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
            ),
            if (trailing != null)
              Text(trailing, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );

    Widget section(String title, List<Widget> children, {Widget? action}) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 14, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 0, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                ),
                ?action,
              ],
            ),
          ),
          ...children,
        ],
      ),
    );

    final context0 = s == null || !ai.ready ? null : chats.contextOf(s, ai);
    final engine = searchEngines[cfg.aiSearchEngine]?.split('（').first ?? '内置';

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          if (onClose != null)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(tooltip: '收起侧边栏', onPressed: onClose, icon: const Icon(Icons.close)),
            ),
          section('环境', [
            row(
              Icons.smart_toy_outlined,
              ai.ready ? ai.model : '还没有设置模型',
              trailing: ai.ready ? ai.host : '设置',
              onTap: () => showAiSettingsDialog(context),
            ),
            row(Icons.sports_esports_outlined, state.selectedVersion?.id ?? '没有选择版本', trailing: '当前版本'),
            row(
              Icons.folder_special_outlined,
              'AI 工作区',
              trailing: cfg.aiTools && cfg.aiWorkspace ? '开' : '关',
              onTap: () => showAiSettingsDialog(context, section: 'aiWorkspace'),
            ),
            row(
              Icons.travel_explore,
              '联网搜索',
              trailing: cfg.aiTools && cfg.aiWeb ? engine : '关',
              onTap: () => showAiSettingsDialog(context, section: 'aiWorkspace'),
            ),
            // 外部 MCP 服务：连接后显示工具数，失败时显示原因
            if (cfg.aiTools && state.chats.hub != null)
              ValueListenableBuilder(
                valueListenable: state.chats.hub!.statusVersion,
                builder: (context, _, _) => Column(
                  children: [
                    for (final s in state.chats.hub!.externals)
                      if (s.config.enabled)
                        row(
                          Icons.extension_outlined,
                          s.name,
                          trailing: s.error != null
                              ? '连接失败'
                              : s.toolCount != null
                              ? '${s.toolCount} 个工具'
                              : '未连接',
                          color: s.error != null ? scheme.error : null,
                          onTap: () => showAiSettingsDialog(context, section: 'aiTools'),
                        ),
                  ],
                ),
              ),
          ]),
          if (context0 != null)
            section(
              '上下文',
              [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text(
                            '${(context0.used / context0.window * 100).clamp(0, 100).toStringAsFixed(0)}% 已用',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const Spacer(),
                          Text(
                            '${context0.estimated ? '约 ' : ''}${_k(context0.used)} / ${_k(context0.window)}',
                            style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: (context0.used / context0.window).clamp(0.0, 1.0),
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ],
                  ),
                ),
              ],
              action: TextButton(
                onPressed: !busy && chats.canCompact(s!) ? () => chats.compact(s, ai) : null,
                child: const Text('压缩'),
              ),
            ),
          section('本次对话的文件', [
            if (files.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Text(
                  'AI 在这次对话里写入或修改的文件会出现在这里',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              )
            else
              for (final f in files.take(20))
                row(
                  _iconFor(f.path),
                  f.path,
                  trailing: f.root == 'workspace' ? null : f.root,
                  color: scheme.primary,
                  onTap: () => openAgentFile(context, f.root, f.path),
                ),
          ]),
          _WorkspaceFiles(version: files.length, row: row, section: section),
        ],
      ),
    );
  }

  static String _k(int v) => v >= 1000000
      ? '${(v / 1000000).toStringAsFixed(1)}M'
      : v >= 1000
      ? '${(v / 1000).toStringAsFixed(v >= 100000 ? 0 : 1)}k'
      : '$v';
}

IconData _iconFor(String path) => switch (p.extension(path).toLowerCase()) {
  '.md' || '.markdown' || '.txt' => Icons.article_outlined,
  '.json' || '.toml' || '.yml' || '.yaml' || '.properties' || '.cfg' => Icons.data_object,
  '.png' || '.jpg' || '.jpeg' => Icons.image_outlined,
  _ => Icons.insert_drive_file_outlined,
};

/// 工作区里的文件，按修改时间排序；对话里有新的文件操作时自动刷新
class _WorkspaceFiles extends StatefulWidget {
  const _WorkspaceFiles({required this.version, required this.row, required this.section});

  final int version;
  final Widget Function(IconData icon, String text, {String? trailing, VoidCallback? onTap, Color? color}) row;
  final Widget Function(String title, List<Widget> children, {Widget? action}) section;

  @override
  State<_WorkspaceFiles> createState() => _WorkspaceFilesState();
}

class _WorkspaceFilesState extends State<_WorkspaceFiles> {
  List<(String rel, DateTime modified)> _files = const [];

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void didUpdateWidget(_WorkspaceFiles old) {
    super.didUpdateWidget(old);
    if (old.version != widget.version) _scan();
  }

  void _scan() {
    final dir = Directory(aiWorkspaceDir);
    final out = <(String, DateTime)>[];
    try {
      if (dir.existsSync()) {
        for (final e in dir.listSync(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          out.add((p.relative(e.path, from: dir.path).replaceAll(r'\', '/'), e.lastModifiedSync()));
          if (out.length >= 500) break;
        }
      }
    } catch (_) {}
    out.sort((a, b) => b.$2.compareTo(a.$2));
    setState(() => _files = out.take(30).toList());
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${t.month}/${t.day}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return widget.section(
      '工作区',
      [
        if (_files.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Text(
              '还是空的。可以让 AI 把整理结果写到这里',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          )
        else
          for (final (rel, modified) in _files)
            widget.row(
              _iconFor(rel),
              rel,
              trailing: _ago(modified),
              onTap: () => openAgentFile(context, 'workspace', rel),
            ),
      ],
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '刷新',
            visualDensity: VisualDensity.compact,
            onPressed: _scan,
            icon: const Icon(Icons.refresh, size: 18),
          ),
          IconButton(
            tooltip: '打开文件夹',
            visualDensity: VisualDensity.compact,
            onPressed: () => openInFileManager(aiWorkspaceDir),
            icon: const Icon(Icons.folder_open_outlined, size: 18),
          ),
        ],
      ),
    );
  }
}
