import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_scope.dart';
import '../app_state.dart';
import '../core/ai/mcp_client.dart';
import '../core/ai/mcp_hub.dart';
import '../pages/file_manager_page.dart' show pickFile;

/// AI 设置里的「工具服务（MCP）」：内置服务的权限，以及用户添加的外部 MCP 服务
class AiMcpSettings extends StatefulWidget {
  const AiMcpSettings({super.key});

  @override
  State<AiMcpSettings> createState() => _AiMcpSettingsState();
}

class _AiMcpSettingsState extends State<AiMcpSettings> {
  McpHub? _hub;
  bool _probing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final hub = AppScope.read(context).chats.hub;
    if (hub == _hub) return;
    _hub?.statusVersion.removeListener(_changed);
    _hub = hub?..statusVersion.addListener(_changed);
    // 打开这一页时连接一次外部服务，显示工具数或失败原因
    _probe();
  }

  @override
  void dispose() {
    _hub?.statusVersion.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _probe() async {
    final hub = _hub;
    if (hub == null || _probing) return;
    setState(() => _probing = true);
    try {
      await hub.probe();
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _setPolicy(AppState state, String id, McpPolicy policy) => state.config.update({
    'aiMcpPolicy': {...state.config.aiMcpPolicy, id: policy.name},
  });

  Future<void> _saveServers(AppState state, List<McpServerConfig> list) => state.config.update({
    'aiMcpServers': [for (final s in list) s.toJson()],
  });

  Future<void> _edit(AppState state, [McpServerConfig? old]) async {
    final saved = await showDialog<_EditResult>(
      context: context,
      builder: (_) => _McpServerDialog(
        state: state,
        old: old,
        policy: old == null ? McpPolicy.ask : McpPolicy.parse(state.config.aiMcpPolicy[old.id]),
      ),
    );
    if (saved == null) return;
    final list = state.config.aiMcpServers;
    final i = list.indexWhere((s) => s.id == saved.config.id);
    if (i < 0) {
      list.add(saved.config);
    } else {
      list[i] = saved.config;
    }
    await McpSecret.save(saved.config.id, saved.token);
    await _saveServers(state, list);
    await _setPolicy(state, saved.config.id, saved.policy);
    // 新的配置马上连接一次，显示状态
    unawaited(_probe());
  }

  Future<void> _remove(AppState state, McpServerConfig s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除 MCP 服务'),
        content: Text('移除「${s.name}」？保存的访问令牌也会一起删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('移除')),
        ],
      ),
    );
    if (ok != true) return;
    await McpSecret.save(s.id, '');
    await _saveServers(state, state.config.aiMcpServers.where((x) => x.id != s.id).toList());
    await state.config.update({
      'aiMcpPolicy': {...state.config.aiMcpPolicy}..remove(s.id),
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = AppScope.of(context);
    final cfg = state.config;
    final hub = state.chats.hub;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    Widget policyMenu(String id, {bool readOnlyTools = false}) {
      if (readOnlyTools) return Text('只有查看类操作', style: muted);
      // 弹出菜单会自动避开屏幕边缘（下拉框贴着右边时菜单会被截掉）
      final current = McpPolicy.parse(cfg.aiMcpPolicy[id]);
      return PopupMenuButton<McpPolicy>(
        initialValue: current,
        tooltip: '权限',
        onSelected: (v) => _setPolicy(state, id, v),
        itemBuilder: (_) => [for (final p in McpPolicy.values) PopupMenuItem(value: p, child: Text(p.label))],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                current.label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: current == McpPolicy.readOnly ? scheme.primary : scheme.onSurface,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.arrow_drop_down, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      );
    }

    final builtins = [
      (id: 'game', icon: Icons.sports_esports_outlined, on: true, readOnly: false),
      (id: 'workspace', icon: Icons.folder_special_outlined, on: cfg.aiWorkspace, readOnly: false),
      (id: 'web', icon: Icons.travel_explore, on: cfg.aiWeb, readOnly: true),
    ];
    final externals = hub?.externals ?? const <ExternalMcpServer>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Text('工具服务（MCP）', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
          'AI 的所有操作都通过这些服务完成。设为「只读」的服务会直接拒绝会修改内容的操作，不再询问。'
          '外部服务只由启动器主动连接，启动器不对外开放任何端口。',
          style: muted,
        ),
        for (final b in builtins)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(b.icon, color: b.on ? scheme.primary : scheme.outline),
            title: Text(hub?.builtins.firstWhere((s) => s.id == b.id).name ?? b.id),
            subtitle: Text(b.on ? '内置' : '内置 · 已在上方关闭'),
            trailing: policyMenu(b.id, readOnlyTools: b.readOnly),
          ),
        for (final s in externals)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              s.config.isJar ? Icons.coffee_outlined : Icons.cloud_outlined,
              color: s.config.enabled ? scheme.primary : scheme.outline,
            ),
            title: Text(s.name),
            subtitle: Text(
              [
                s.config.isJar ? p.basename(s.config.jar) : s.config.url,
                McpPolicy.parse(cfg.aiMcpPolicy[s.id]).label,
                if (s.config.trusted) '信任只读声明',
                if (s.error != null)
                  '连接失败：${s.error!.split('\n').first}'
                else if (s.toolCount != null)
                  '${s.toolCount} 个工具',
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: s.error != null ? TextStyle(color: scheme.error) : null,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: s.config.enabled,
                  onChanged: (v) => _saveServers(state, [
                    for (final x in cfg.aiMcpServers) x.id == s.id ? x.copyWith(enabled: v) : x,
                  ]),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) => v == 'edit' ? _edit(state, s.config) : _remove(state, s.config),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'remove', child: Text('移除')),
                  ],
                ),
              ],
            ),
          ),
        Row(
          children: [
            TextButton.icon(onPressed: () => _edit(state), icon: const Icon(Icons.add), label: const Text('添加 MCP 服务')),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _probing ? null : _probe,
              icon: const Icon(Icons.refresh),
              label: Text(_probing ? '正在连接…' : '刷新状态'),
            ),
          ],
        ),
      ],
    );
  }
}

class _EditResult {
  const _EditResult(this.config, this.token, this.policy);

  final McpServerConfig config;
  final String token;
  final McpPolicy policy;
}

class _McpServerDialog extends StatefulWidget {
  const _McpServerDialog({required this.state, required this.old, required this.policy});

  final AppState state;
  final McpServerConfig? old;
  final McpPolicy policy;

  @override
  State<_McpServerDialog> createState() => _McpServerDialogState();
}

class _McpServerDialogState extends State<_McpServerDialog> {
  late final _name = TextEditingController(text: widget.old?.name ?? '');
  late final _url = TextEditingController(text: widget.old?.url ?? '');
  late final _token = TextEditingController(text: widget.old == null ? '' : McpSecret.load(widget.old!.id));
  late final _jar = TextEditingController(text: widget.old?.jar ?? '');
  late final _args = TextEditingController(text: widget.old?.args.join(' ') ?? '');
  late String _type = widget.old?.type ?? 'http';
  late McpPolicy _policy = widget.policy;
  late bool _trusted = widget.old?.trusted ?? false;
  bool _showToken = false;
  bool _testing = false;
  String? _result;
  bool _ok = false;

  @override
  void dispose() {
    for (final c in [_name, _url, _token, _jar, _args]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 当前填写的配置；有问题时返回说明
  (McpServerConfig?, String?) _build() {
    final name = _name.text.trim();
    if (name.isEmpty) return (null, '请填写名称');
    if (_type == 'http') {
      final bad = checkMcpUrl(_url.text);
      if (bad != null) return (null, bad);
    } else {
      if (Platform.isAndroid) return (null, '安卓上暂时还不能运行本机 jar 服务');
      if (!File(_jar.text.trim()).existsSync()) return (null, '请选择 jar 文件');
    }
    final id = widget.old?.id ?? newMcpId(name, widget.state.config.aiMcpServers.map((s) => s.id));
    return (
      McpServerConfig(
        id: id,
        name: name,
        type: _type,
        url: _url.text.trim(),
        jar: _jar.text.trim(),
        args: _args.text.trim().isEmpty ? const [] : _args.text.trim().split(RegExp(r'\s+')),
        enabled: widget.old?.enabled ?? true,
        trusted: _trusted,
      ),
      null,
    );
  }

  Future<void> _test() async {
    final (c, bad) = _build();
    if (c == null) {
      setState(() {
        _result = bad;
        _ok = false;
      });
      return;
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    // 测试用临时 id，令牌只在这次连接中使用
    final probe = McpServerConfig(id: '${c.id}test', name: c.name, type: c.type, url: c.url, jar: c.jar, args: c.args);
    try {
      await McpSecret.save(probe.id, _token.text);
      final r = await testMcpServer(probe, widget.state);
      final names = r.tools.map((t) => t.name).take(8).join('、');
      _ok = true;
      _result =
          '连接成功${r.server.isEmpty ? '' : '（${r.server}）'}，提供 ${r.tools.length} 个工具'
          '${names.isEmpty ? '' : '：$names${r.tools.length > 8 ? '…' : ''}'}';
    } catch (e) {
      _ok = false;
      _result = '$e';
    } finally {
      await McpSecret.save(probe.id, '');
    }
    if (mounted) setState(() => _testing = false);
  }

  Future<void> _pickJar() async {
    final path = await pickFile(context, extensions: const ['jar'], label: 'jar 文件');
    if (path != null) setState(() => _jar.text = path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: Text(widget.old == null ? '添加 MCP 服务' : '编辑 MCP 服务'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '名称', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: [
                  const ButtonSegment(value: 'http', label: Text('远程（HTTP）'), icon: Icon(Icons.cloud_outlined)),
                  ButtonSegment(
                    value: 'jar',
                    label: const Text('本机 jar'),
                    icon: const Icon(Icons.coffee_outlined),
                    enabled: !Platform.isAndroid,
                  ),
                ],
                selected: {_type},
                onSelectionChanged: widget.old == null ? (v) => setState(() => _type = v.first) : null,
              ),
              const SizedBox(height: 12),
              if (_type == 'http') ...[
                TextField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: '服务地址',
                    hintText: 'https://example.com/mcp',
                    helperText: '远程服务需要 https；本机服务（例如 Termux 里运行的）可以填 http://127.0.0.1:端口/mcp',
                    helperMaxLines: 3,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _token,
                  obscureText: !_showToken,
                  decoration: InputDecoration(
                    labelText: '访问令牌（可选）',
                    helperText: '加密保存在本机，只会发给这个服务（Authorization: Bearer）',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _showToken = !_showToken),
                      icon: Icon(_showToken ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    ),
                  ),
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _jar,
                        decoration: const InputDecoration(labelText: 'jar 文件', border: OutlineInputBorder()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(onPressed: _pickJar, icon: const Icon(Icons.folder_open_outlined)),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _args,
                  decoration: const InputDecoration(
                    labelText: '启动参数（可选）',
                    helperText: '用空格分隔，附加在 java -jar 文件 之后；Java 由启动器自动选择（Java 21）',
                    helperMaxLines: 2,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<McpPolicy>(
                initialValue: _policy,
                decoration: const InputDecoration(labelText: '权限', border: OutlineInputBorder()),
                items: [for (final p in McpPolicy.values) DropdownMenuItem(value: p, child: Text(p.label))],
                onChanged: (v) => setState(() => _policy = v ?? McpPolicy.ask),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('信任这个服务的只读声明'),
                subtitle: const Text(
                  '打开后，服务声明只读的工具直接执行，不用确认；关闭时，每个工具在本次对话中第一次使用都要确认。'
                  '声明会删除内容的工具始终每次确认。只对你信任的服务打开',
                ),
                value: _trusted,
                onChanged: (v) => setState(() => _trusted = v),
              ),
              if (_result != null) ...[
                const SizedBox(height: 12),
                Text(_result!, style: TextStyle(color: _ok ? scheme.primary : scheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _testing ? null : _test, child: Text(_testing ? '正在连接…' : '测试连接')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final (c, bad) = _build();
            if (c == null) {
              setState(() {
                _result = bad;
                _ok = false;
              });
              return;
            }
            Navigator.pop(context, _EditResult(c, _token.text, _policy));
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
