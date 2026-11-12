import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import '../core/android_storage.dart';
import 'file_manager_page.dart';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../app_state.dart';
import '../widgets/version_icon.dart';
import '../widgets/launch_dialogs.dart';
import '../core/android_runtime.dart';
import '../core/config.dart';
import '../core/instance.dart';
import '../core/instance_config.dart';
import '../core/instance_files.dart';
import '../core/java.dart';
import '../core/memory.dart';
import '../shell.dart';
import '../core/extra_loaders.dart';
import '../core/loader_names.dart';
import '../core/loaders.dart';
import '../core/optifine_compat.dart';
import '../widgets/format.dart';
import '../widgets/loader_icon.dart';
import '../widgets/settings_group.dart';
import '../widgets/side_nav.dart';

enum _Section { overview, setup, saves, screenshots, mods, resourcepacks, shaderpacks, schematics, servers }

const _folders = {
  _Section.saves: InstanceFolder.saves,
  _Section.screenshots: InstanceFolder.screenshots,
  _Section.mods: InstanceFolder.mods,
  _Section.resourcepacks: InstanceFolder.resourcepacks,
  _Section.shaderpacks: InstanceFolder.shaderpacks,
  _Section.schematics: InstanceFolder.schematics,
};

/// 版本详情：顶部是封面、名称和常用操作，下面一排标签（模组、存档、资源包……、设置、概览）
class InstancePage extends StatefulWidget {
  const InstancePage({super.key});

  @override
  State<InstancePage> createState() => _InstancePageState();
}

class _InstancePageState extends State<InstancePage> {
  _Section? _section;

  Future<void> _launch(InstanceInfo info) async {
    final state = AppScope.read(context);
    if (state.selectedVersion?.id != info.id) await state.selectVersion(info.id);
    if (!mounted) return;
    final view = View.of(context);
    final display = PlatformDispatcher.instance.displays.firstOrNull;
    final launcher = view.physicalSize / view.devicePixelRatio;
    final screen = display == null ? launcher : display.size / display.devicePixelRatio;
    try {
      await state.launch(
        DialogLaunchPrompts(context),
        launcherSize: (width: launcher.width.round(), height: launcher.height.round()),
        screenSize: (width: screen.width.round(), height: screen.height.round()),
      );
    } catch (e) {
      if (mounted) toast(context, '启动失败：${errorText(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = AppScope.of(context);
    final info = state.instance(state.instanceId);
    if (info == null) {
      return const Center(child: Text('这个版本已不存在'));
    }
    final tabs = <(_Section, String)>[
      // 与 PCL 一样，没有加载器的版本不显示模组
      if (info.modable) (_Section.mods, '模组'),
      (_Section.saves, '存档'),
      (_Section.resourcepacks, '资源包'),
      (_Section.shaderpacks, '光影'),
      (_Section.screenshots, '截图'),
      (_Section.schematics, '投影'),
      (_Section.servers, '服务器'),
      (_Section.setup, '版本设置'),
      (_Section.overview, '概览'),
    ];
    final section = tabs.any((t) => t.$1 == _section) ? _section! : tabs.first.$1;
    final folder = _folders[section];
    final running = state.gameState != GameState.idle;
    return FutureBuilder(
      future: state.gameDirOf(info),
      builder: (context, snap) {
        final dir = snap.data;
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  // 点图标更换或恢复默认
                  PopupMenuButton<String>(
                    tooltip: '更换图标',
                    onSelected: (v) async {
                      final dir = state.paths.versionDir(info.id);
                      try {
                        if (v == 'pick') await pickVersionLogo(dir);
                        if (v == 'reset') await resetVersionLogo(dir);
                      } catch (e) {
                        if (context.mounted) toast(context, '更换图标失败：${errorText(e)}');
                      }
                      if (mounted) setState(() {});
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'pick', child: Text('更换图标…')),
                      PopupMenuItem(
                        value: 'reset',
                        enabled: customVersionLogo(state.paths.versionDir(info.id)) != null,
                        child: const Text('恢复默认图标'),
                      ),
                    ],
                    child: VersionIcon(info: info, versionDir: state.paths.versionDir(info.id), size: 48),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          versionTitle(info),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          versionTitle(info) == info.id ? describeVersion(info) : info.id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: dir == null
                        ? null
                        : () async {
                            try {
                              await openInFileManager(dir);
                            } catch (e) {
                              if (context.mounted) toast(context, '打不开文件夹：${errorText(e)}');
                            }
                          },
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                    icon: const Icon(Icons.folder_outlined, size: 18),
                    label: const Text('打开文件夹'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: running ? null : () => _launch(info),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                    icon: const Icon(Icons.rocket_launch, size: 19),
                    label: const Text('开始游戏'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              PageTabs<_Section>(tabs: tabs, value: section, onChanged: (s) => setState(() => _section = s)),
              const SizedBox(height: 6),
              Expanded(
                child: dir == null
                    ? const Center(child: CircularProgressIndicator())
                    : KeyedSubtree(
                        key: ValueKey('${info.id}-$section'),
                        child: switch (section) {
                          _Section.overview => _Overview(info: info, gameDir: dir),
                          _Section.setup => _Setup(info: info),
                          _Section.servers => _Servers(gameDir: dir),
                          _ => _Files(info: info, gameDir: dir, folder: folder!),
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------- 概览 ----------

class _Overview extends StatelessWidget {
  const _Overview({required this.info, required this.gameDir});

  final InstanceInfo info;
  final String gameDir;

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text('删除 ${info.id}？'),
        content: const Text('版本文件夹会移到回收站。开启版本隔离时，其中的存档和模组也会一并删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final state = AppScope.read(context);
    final nav = ShellNav.of(context);
    try {
      await state.deleteVersion(info.id);
      nav.back();
      if (context.mounted) toast(context, '已删除 ${info.id}');
    } catch (e) {
      if (context.mounted) toast(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = AppScope.of(context);
    final current = state.config.selectedVersion == info.id;
    final versionDir = state.paths.versionDir(info.id);
    Widget row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(k, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
          Expanded(child: Text(v)),
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(info.id, style: theme.textTheme.headlineSmall, overflow: TextOverflow.ellipsis),
            ),
            if (current)
              Chip(
                label: const Text('当前版本'),
                avatar: Icon(Icons.check, color: scheme.primary),
              )
            else
              FilledButton.tonal(onPressed: () => state.selectVersion(info.id), child: const Text('设为当前版本')),
          ],
        ),
        const SizedBox(height: 16),
        Card.filled(
          color: scheme.surfaceContainerLow,
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Column(
              children: [
                row('类型', describeVersion(info)),
                row('游戏版本', info.gameVersion),
                row('版本隔离', info.isolation == null ? '首次启动时决定' : (info.isolation! ? '已开启' : '已关闭')),
                row('运行目录', gameDir),
                // 加载器版本文件里的时间是加载器的构建时间，只对原版显示
                if (info.releaseTime != null && info.loader == Loader.vanilla)
                  row('发布时间', DateTime.tryParse(info.releaseTime!)?.toLocal().toString().split('.').first ?? ''),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('快捷方式', style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => openInFileManager(versionDir),
              icon: const Icon(Icons.folder_open),
              label: const Text('版本文件夹'),
            ),
            for (final f in [
              InstanceFolder.saves,
              InstanceFolder.mods,
              InstanceFolder.resourcepacks,
              InstanceFolder.screenshots,
            ])
              OutlinedButton.icon(
                onPressed: () => openInFileManager('$gameDir${Platform.pathSeparator}${f.name}'),
                icon: const Icon(Icons.folder_outlined),
                label: Text('${f.label}文件夹'),
              ),
          ],
        ),
        const SizedBox(height: 24),
        Text('管理', style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 12),
        Card.filled(
          color: scheme.surfaceContainerLow,
          margin: EdgeInsets.zero,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            leading: Icon(Icons.delete_outline, color: scheme.error),
            title: const Text('删除这个版本'),
            subtitle: const Text('移到回收站；开启版本隔离时，其中的存档和模组也会一并删除'),
            trailing: OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
              onPressed: () => _delete(context),
              child: const Text('删除'),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------- 独立设置 ----------

/// 版本独立设置，直接读写 `versions/<id>/PCL/config.v1.yml`，与 PCL-CE 共用
class _Setup extends StatefulWidget {
  const _Setup({required this.info});

  final InstanceInfo info;

  @override
  State<_Setup> createState() => _SetupState();
}

class _SetupState extends State<_Setup> {
  late InstanceSettings _s;
  List<JavaInfo> _javas = [];

  String get _dir => AppScope.read(context).paths.versionDir(widget.info.id);

  @override
  void initState() {
    super.initState();
    _s = readInstanceSettings(AppScope.read(context).paths.versionDir(widget.info.id));
    if (Platform.isAndroid) {
      _javas = installedAndroidJavas();
    } else {
      listJavas().then((j) => mounted ? setState(() => _javas = j) : null);
    }
  }

  Future<void> _save(Map<String, Object> patch) async {
    try {
      await writeInstanceRaw(_dir, patch);
      if (!mounted) return;
      setState(() => _s = readInstanceSettings(_dir));
      if (patch.containsKey('VersionArgumentIndieV2')) await AppScope.read(context).refreshVersions();
    } catch (e) {
      if (mounted) toast(context, errorText(e));
    }
  }

  String get _javaKey => switch (_s.java) {
    JavaGlobal() => 'global',
    JavaAuto() => 'auto',
    JavaExist(:final path) || JavaRelative(:final path) => 'path:$path',
  };

  Future<void> _chooseJava(String key) async {
    if (key == 'browse') {
      final path = await pickFile(context, label: 'Java', start: Platform.isAndroid ? AndroidStorage.root : null);
      if (path == null) return;
      return _save({'VersionArgumentJavaSelect': serializeJava(JavaExist(path))});
    }
    final pref = switch (key) {
      'global' => const JavaGlobal(),
      'auto' => const JavaAuto(),
      _ => JavaExist(key.substring(5)),
    };
    await _save({'VersionArgumentJavaSelect': serializeJava(pref)});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cfg = AppScope.of(context).config;
    final mem = systemMemory();
    final maxTick = maxTickFor(mem.total);
    const pad = EdgeInsets.symmetric(horizontal: 20, vertical: 8);
    final javaOptions = <String, String>{
      'global': '跟随全局设置',
      'auto': '自动选择',
      for (final j in _javas) 'path:${j.path}': Platform.isAndroid ? 'Java ${j.major}' : 'Java ${j.major} · ${j.path}',
      if (_javaKey.startsWith('path:') && !_javas.any((j) => 'path:${j.path}' == _javaKey))
        _javaKey: Platform.isAndroid ? '${_javaKey.substring(5)}（未安装）' : _javaKey.substring(5),
      if (!Platform.isAndroid) 'browse': '手动选择…',
    };
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            children: [
              Icon(Icons.sync_alt, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '这些设置保存在版本文件夹的 PCL/config.v1.yml 中，与 PCL-CE 互通',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        SettingsGroup(
          title: '启动',
          children: [
            ListTile(
              contentPadding: pad,
              leading: const Icon(Icons.call_split),
              title: const Text('版本隔离'),
              subtitle: Text(
                _s.isolation == null ? '尚未决定：首次启动时按全局策略「${isolationModes[cfg.isolationMode]}」决定，之后固定' : '运行目录为版本文件夹',
              ),
              trailing: SegmentedButton<bool>(
                emptySelectionAllowed: true,
                segments: const [
                  ButtonSegment(value: true, label: Text('开启')),
                  ButtonSegment(value: false, label: Text('关闭')),
                ],
                selected: {?_s.isolation},
                onSelectionChanged: (v) => v.isEmpty ? null : _save({'VersionArgumentIndieV2': v.first}),
              ),
            ),
            ListTile(
              contentPadding: pad,
              leading: const Icon(Icons.coffee_outlined),
              title: const Text('Java'),
              trailing: DropdownMenu<String>(
                key: ValueKey(_javaKey + _javas.length.toString()),
                width: 320,
                initialSelection: _javaKey,
                requestFocusOnTap: false,
                inputDecorationTheme: const InputDecorationTheme(isDense: true, border: OutlineInputBorder()),
                dropdownMenuEntries: [
                  for (final e in javaOptions.entries) DropdownMenuEntry(value: e.key, label: e.value),
                ],
                onSelected: (v) => v == null ? null : _chooseJava(v),
              ),
            ),
            if (Platform.isAndroid)
              ListTile(
                contentPadding: pad,
                leading: const Icon(Icons.memory),
                title: const Text('渲染器'),
                subtitle: Text(
                  _s.renderer.isEmpty
                      ? '跟随全局设置「${androidRenderers[cfg.androidRenderer] ?? cfg.androidRenderer}」'
                      : androidRendererHints[_s.renderer] ?? '',
                ),
                trailing: DropdownMenu<String>(
                  key: ValueKey(_s.renderer),
                  width: 320,
                  initialSelection: _s.renderer,
                  requestFocusOnTap: false,
                  inputDecorationTheme: const InputDecorationTheme(isDense: true, border: OutlineInputBorder()),
                  dropdownMenuEntries: [
                    const DropdownMenuEntry(value: '', label: '跟随全局设置'),
                    for (final e in androidRenderers.entries) DropdownMenuEntry(value: e.key, label: e.value),
                  ],
                  onSelected: (v) => v == null ? null : _save({'PclpwAndroidRenderer': v}),
                ),
              ),
          ],
        ),
        SettingsGroup(
          title: '游戏内存',
          children: [
            ListTile(
              contentPadding: pad,
              leading: const Icon(Icons.memory_outlined),
              title: const Text('分配方式'),
              trailing: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'global', label: Text('跟随全局')),
                  ButtonSegment(value: 'auto', label: Text('自动')),
                  ButtonSegment(value: 'custom', label: Text('自定义')),
                ],
                selected: {_s.memoryMode},
                onSelectionChanged: (v) => _save({
                  'VersionRamType': const {'auto': 0, 'custom': 1, 'global': 2}[v.first]!,
                }),
              ),
            ),
            if (_s.memoryMode == 'custom')
              for (final (label, key, value, min) in [
                ('最大内存', 'VersionRamCustom', _s.memoryTick, 1),
                ('初始内存', 'VersionRamCustomInitial', _s.memoryInitialTick, 0),
              ])
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Row(
                    children: [
                      const SizedBox(width: 40),
                      SizedBox(width: 72, child: Text(label)),
                      Expanded(
                        child: Slider(
                          value: value.clamp(min, maxTick).toDouble(),
                          min: min.toDouble(),
                          max: maxTick.toDouble(),
                          divisions: maxTick - min,
                          onChanged: (v) => setState(
                            () => _s = InstanceSettings(
                              isolation: _s.isolation,
                              memoryMode: _s.memoryMode,
                              memoryTick: key == 'VersionRamCustom' ? v.round() : _s.memoryTick,
                              memoryInitialTick: key == 'VersionRamCustomInitial' ? v.round() : _s.memoryInitialTick,
                              jvmArgs: _s.jvmArgs,
                              gameArgs: _s.gameArgs,
                              java: _s.java,
                              server: _s.server,
                              versionType: _s.versionType,
                              title: _s.title,
                              preLaunchCommand: _s.preLaunchCommand,
                              preLaunchWait: _s.preLaunchWait,
                              classpathHead: _s.classpathHead,
                              renderer: _s.renderer,
                            ),
                          ),
                          onChangeEnd: (v) => _save({key: v.round()}),
                        ),
                      ),
                      SizedBox(
                        width: 72,
                        child: Text(
                          value == 0 ? '不设置' : '${ramFromTick(value).toStringAsFixed(1)} GB',
                          textAlign: TextAlign.end,
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
        SettingsGroup(
          title: '高级',
          children: [
            for (final (icon, title, key, value, hint) in [
              (Icons.dns_outlined, '自动进入服务器', 'VersionServerEnter', _s.server, 'mc.example.com:25565'),
              (Icons.label_outline, '版本类型显示', 'VersionArgumentInfo', _s.versionType, '留空则使用全局设置'),
              (Icons.code, 'JVM 参数', 'VersionAdvanceJvm', _s.jvmArgs, '留空则使用全局设置'),
              (Icons.terminal, '游戏参数', 'VersionAdvanceGame', _s.gameArgs, '留空则使用全局设置'),
              (Icons.play_circle_outline, '启动前执行命令', 'VersionAdvanceRun', _s.preLaunchCommand, ''),
            ])
              _InstanceTextRow(
                key: ValueKey(key),
                icon: icon,
                title: title,
                value: value,
                hint: hint,
                onSaved: (v) => _save({key: v}),
              ),
          ],
        ),
      ],
    );
  }
}

class _InstanceTextRow extends StatefulWidget {
  const _InstanceTextRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.hint,
    required this.onSaved,
  });

  final IconData icon;
  final String title;
  final String value;
  final String hint;
  final ValueChanged<String> onSaved;

  @override
  State<_InstanceTextRow> createState() => _InstanceTextRowState();
}

class _InstanceTextRowState extends State<_InstanceTextRow> {
  late final _c = TextEditingController(text: widget.value);
  late final FocusNode _focus = FocusNode()..addListener(() => _focus.hasFocus ? null : _save());

  void _save() {
    if (_c.text != widget.value) widget.onSaved(_c.text);
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
    child: Row(
      children: [
        Icon(widget.icon),
        const SizedBox(width: 16),
        SizedBox(width: 140, child: Text(widget.title)),
        Expanded(
          child: TextField(
            controller: _c,
            focusNode: _focus,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(hintText: widget.hint, isDense: true, border: const OutlineInputBorder()),
          ),
        ),
      ],
    ),
  );
}

// ---------- 资源文件夹 ----------

class _Files extends StatefulWidget {
  const _Files({required this.info, required this.gameDir, required this.folder});

  final InstanceInfo info;
  final String gameDir;
  final InstanceFolder folder;

  @override
  State<_Files> createState() => _FilesState();
}

class _FilesState extends State<_Files> {
  late List<InstanceFile> _files = listInstanceFiles(widget.gameDir, widget.folder);
  String _query = '';

  String get _dir => '${widget.gameDir}${Platform.pathSeparator}${widget.folder.name}';

  void _refresh() => setState(() => _files = listInstanceFiles(widget.gameDir, widget.folder));

  Future<void> _trash(InstanceFile f) async {
    try {
      await moveToTrash(f.path);
      _refresh();
      if (mounted) toast(context, '已将 ${f.name} 移到回收站');
    } catch (e) {
      if (mounted) toast(context, errorText(e));
    }
  }

  Future<void> _toggle(InstanceFile f) async {
    try {
      await setModEnabled(f, f.disabled);
      _refresh();
    } catch (e) {
      if (mounted) toast(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final q = _query.toLowerCase();
    final shown = _files.where((f) => q.isEmpty || f.name.toLowerCase().contains(q)).toList();
    final isShots = widget.folder == InstanceFolder.screenshots;
    final isMods = widget.folder == InstanceFolder.mods;
    final enabledMods = isMods ? _files.where((f) => !f.disabled).length : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 16, 8),
          child: Row(
            children: [
              Text(widget.folder.label, style: theme.textTheme.headlineSmall),
              const SizedBox(width: 12),
              Text(
                isMods ? '${_files.length} 个，已启用 $enabledMods 个' : '${_files.length} 个',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              if (!isShots)
                SizedBox(
                  width: 200,
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '筛选',
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(28))),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
              if (isMods && canAddOptiFine(widget.info.loader))
                TextButton.icon(
                  onPressed: () async {
                    await showDialog<void>(
                      context: context,
                      builder: (_) => _AddOptiFineDialog(info: widget.info),
                    );
                    _refresh();
                  },
                  icon: const LoaderIcon(Loader.optifine, size: 18),
                  label: const Text('添加 OptiFine'),
                ),
              IconButton(tooltip: '刷新', onPressed: _refresh, icon: const Icon(Icons.refresh)),
              TextButton.icon(
                onPressed: () => openInFileManager(_dir),
                icon: const Icon(Icons.folder_open),
                label: const Text('打开文件夹'),
              ),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Text('这里还没有${widget.folder.label}', style: TextStyle(color: scheme.onSurfaceVariant)),
                )
              : isShots
              ? GridView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 260,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 16 / 10,
                  ),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final f = shown[i];
                    return Tooltip(
                      message: '${f.name}\n${formatDate(f.modified)}',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Material(
                          child: InkWell(
                            onTap: () => openInFileManager(f.path, create: false),
                            onSecondaryTap: () => _trash(f),
                            child: Image.file(File(f.path), fit: BoxFit.cover, cacheWidth: 520),
                          ),
                        ),
                      ),
                    );
                  },
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final f = shown[i];
                    final name = f.disabled ? f.name.substring(0, f.name.length - '.disabled'.length) : f.name;
                    return Card.filled(
                      color: scheme.surfaceContainerLow,
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        leading: Icon(
                          f.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
                          color: f.disabled ? scheme.outline : scheme.primary,
                        ),
                        title: Text(
                          name,
                          overflow: TextOverflow.ellipsis,
                          style: f.disabled
                              ? TextStyle(color: scheme.outline, decoration: TextDecoration.lineThrough)
                              : null,
                        ),
                        subtitle: Text(
                          '${formatDate(f.modified)}${f.isDir ? '' : ' · ${formatSize(f.size)}'}${f.disabled ? ' · 已禁用' : ''}',
                        ),
                        onTap: () => openInFileManager(f.path, create: false),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isMods) Switch(value: !f.disabled, onChanged: (_) => _toggle(f)),
                            IconButton(
                              tooltip: '移到回收站',
                              onPressed: () => _trash(f),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ---------- 服务器 ----------

class _Servers extends StatelessWidget {
  const _Servers({required this.gameDir});

  final String gameDir;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final servers = savedServers(gameDir);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('服务器', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          '游戏内多人游戏列表中保存的服务器（servers.dat）',
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (servers.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text('还没有保存的服务器', style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          ),
        for (final s in servers)
          Card.filled(
            color: scheme.surfaceContainerLow,
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              leading: Icon(Icons.dns_outlined, color: scheme.primary),
              title: Text(s.name),
              subtitle: Text(s.address),
            ),
          ),
      ],
    );
  }
}

/// 给已安装的版本添加 OptiFine：作为模组放进 mods（参照 PCL）
class _AddOptiFineDialog extends StatefulWidget {
  const _AddOptiFineDialog({required this.info});

  final InstanceInfo info;

  @override
  State<_AddOptiFineDialog> createState() => _AddOptiFineDialogState();
}

class _AddOptiFineDialogState extends State<_AddOptiFineDialog> {
  late final Future<List<LoaderVersion>> _future = optiFineVersions(
    AppScope.read(context).downloader,
    widget.info.gameVersion,
  ).then((all) => optiFineFor(widget.info.loader, all));
  String? _version;
  bool _running = false;
  String? _error;

  Future<void> _add() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      await AppScope.read(context).addOptiFineMod(widget.info, _version!);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: const LoaderIcon(Loader.optifine, size: 28),
      title: const Text('添加 OptiFine'),
      content: SizedBox(
        width: 460,
        child: FutureBuilder(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return Text('获取 OptiFine 版本失败：${errorText(snap.error!)}');
            if (!snap.hasData) return const LinearProgressIndicator();
            final list = snap.data!;
            if (list.isEmpty) {
              return Text(
                widget.info.loader == Loader.forge
                    ? '没有与 Forge 兼容的 OptiFine（${widget.info.gameVersion}）'
                    : '${widget.info.gameVersion} 没有可用的 OptiFine',
              );
            }
            _version ??= (list.where((v) => v.stable).firstOrNull ?? list.first).version;
            final selected = list.where((v) => v.version == _version).firstOrNull;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownMenu<String>(
                  expandedInsets: EdgeInsets.zero,
                  label: const Text('OptiFine 版本'),
                  initialSelection: _version,
                  menuHeight: 300,
                  dropdownMenuEntries: [
                    for (final l in list.take(40))
                      DropdownMenuEntry(
                        value: l.version,
                        label:
                            '${l.label}${l.stable ? '' : '（预览版）'}'
                            '${widget.info.loader == Loader.forge && (l.requiredForge?.isNotEmpty ?? false) ? ' · 需要 Forge ${l.requiredForge}' : ''}',
                      ),
                  ],
                  onSelected: (v) => setState(() => _version = v),
                ),
                const SizedBox(height: 12),
                Text(optiFineNote(widget.info.loader, selected), style: TextStyle(color: scheme.onSurfaceVariant)),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: scheme.error)),
                ],
                if (_running) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: _running ? null : () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _running || _version == null ? null : _add, child: const Text('添加')),
      ],
    );
  }
}
