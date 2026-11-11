import 'dart:io';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/ai/agent_root.dart';
import '../core/ai/web_tools.dart';
import '../core/instance_files.dart';
import '../pages/file_manager_page.dart';

/// AI 设置里的「工作区」和「联网」部分（在「允许 AI 操作游戏文件」打开时显示）
class AiWorkspaceSettings extends StatefulWidget {
  const AiWorkspaceSettings({super.key});

  @override
  State<AiWorkspaceSettings> createState() => _AiWorkspaceSettingsState();
}

class _AiWorkspaceSettingsState extends State<AiWorkspaceSettings> {
  final _searchUrl = TextEditingController();
  final _searchKey = TextEditingController();
  bool _loaded = false;
  bool _showKey = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _searchUrl.text = AppScope.read(context).config.aiSearchUrl;
    _searchKey.text = SearchKey.load(AppScope.read(context).config.aiSearchEngine);
  }

  @override
  void dispose() {
    _searchUrl.dispose();
    _searchKey.dispose();
    super.dispose();
  }

  Future<void> _addRoot() async {
    final cfg = AppScope.read(context).config;
    final path = await pickFolder(context, confirm: '让 AI 访问这个文件夹');
    if (path == null || !mounted) return;
    final dir = Directory(path);
    if (!dir.existsSync()) return;
    final real = dir.resolveSymbolicLinksSync();
    final roots = cfg.aiUserRoots;
    if (roots.any((r) => r['path'] == real)) {
      toast(context, '这个文件夹已经添加过了');
      return;
    }
    // 磁盘根目录等于整个盘都交给 AI，单独确认
    final whole = Directory(real).parent.path == real;
    if (whole) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('允许访问整个磁盘？'),
          content: Text('$real 是磁盘的根目录，AI 将能看到其中所有文件。建议只添加需要的文件夹。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('仍然添加')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final id = newRootId(real, roots.map((r) => '${r['id']}'));
    final label = real.split(RegExp(r'[\\/]')).lastWhere((s) => s.isNotEmpty, orElse: () => real);
    // 默认只读，需要时再在列表里打开「允许修改」
    await cfg.update({
      'aiUserRoots': [
        ...roots,
        {'id': id, 'label': label, 'path': real, 'writable': false},
      ],
    });
  }

  Future<void> _updateRoot(String id, Map<String, dynamic>? change) async {
    final cfg = AppScope.read(context).config;
    await cfg.update({
      'aiUserRoots': [
        for (final r in cfg.aiUserRoots)
          if (r['id'] != id) r else if (change != null) {...r, ...change},
      ],
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cfg = AppScope.of(context).config;
    final engine = searchEngines.containsKey(cfg.aiSearchEngine) ? cfg.aiSearchEngine : 'auto';
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('AI 工作区'),
          subtitle: const Text('AI 有一个自己的文件夹可以随意读写，并能查看当前版本的游戏文件（只读）'),
          value: cfg.aiWorkspace,
          onChanged: (v) => cfg.update({'aiWorkspace': v}),
        ),
        if (cfg.aiWorkspace) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              Platform.isAndroid ? '授予「所有文件访问」后，AI 也能读写系统下载目录。' : '还可以添加其他文件夹；默认只读，打开「允许修改」后 AI 才能改动其中的文件。',
              style: muted,
            ),
          ),
          for (final r in cfg.aiUserRoots)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(Icons.folder_outlined, color: scheme.primary),
              title: Text('${r['label']}'),
              subtitle: Text('${r['path']}', maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('允许修改', style: muted),
                  Switch(value: r['writable'] == true, onChanged: (v) => _updateRoot('${r['id']}', {'writable': v})),
                  IconButton(
                    tooltip: '移除（不会删除文件夹）',
                    onPressed: () => _updateRoot('${r['id']}', null),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _addRoot,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('添加文件夹'),
              ),
              TextButton.icon(
                onPressed: () => openInFileManager(aiWorkspaceDir),
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: const Text('打开工作区'),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('联网搜索'),
          subtitle: const Text('AI 可以搜索网页、打开网址、查 Minecraft Wiki；请求会跟随系统代理'),
          value: cfg.aiWeb,
          onChanged: (v) => cfg.update({'aiWeb': v}),
        ),
        if (cfg.aiWeb) ...[
          DropdownButtonFormField<String>(
            initialValue: engine,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '搜索引擎', border: OutlineInputBorder()),
            items: [for (final e in searchEngines.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) {
              cfg.update({'aiSearchEngine': v ?? 'auto'});
              // 每个服务的 Key 分开保存，切换后显示对应服务的 Key
              setState(() => _searchKey.text = SearchKey.load(v ?? 'auto'));
            },
          ),
          if (engine == 'searxng') ...[
            const SizedBox(height: 12),
            TextField(
              controller: _searchUrl,
              decoration: const InputDecoration(
                labelText: 'SearXNG 地址',
                hintText: 'https://searx.example.com',
                helperText: '实例需要开启 JSON 格式输出',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => cfg.update({'aiSearchUrl': v.trim()}),
            ),
          ],
          if (searchEngineTakesKey(engine)) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _searchKey,
              obscureText: !_showKey,
              decoration: InputDecoration(
                labelText: switch (engine) {
                  'exa' => 'Exa 的 API Key（可以不填）',
                  'deepseek' => 'DeepSeek 的 API Key（模型是 DeepSeek 时可以不填）',
                  _ => '搜索服务的 API Key',
                },
                helperText: switch (engine) {
                  'exa' => '不填也能用，有频率限制；填了之后额度更高。只会发给 Exa',
                  'deepseek' => '不填时用模型的 Key。每 1000 次搜索约 0.75 美元，只会发给 DeepSeek',
                  _ => '和模型的 Key 分开保存，只会发给所选的搜索服务',
                },
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _showKey = !_showKey),
                  icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                ),
              ),
              onChanged: (v) => SearchKey.save(engine, v),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}
