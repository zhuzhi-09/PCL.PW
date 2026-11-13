import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_scope.dart';
import '../core/android_storage.dart';
import '../core/instance_files.dart';
import '../core/paths.dart';
import '../platform.dart';
import '../widgets/format.dart';
import '../widgets/side_nav.dart';

/// 选择文件夹：桌面端用系统对话框，手机上用内置的文件管理器
Future<String?> pickFolder(BuildContext context, {String? start, String confirm = '选择'}) async {
  if (isDesktop) return getDirectoryPath(initialDirectory: start, confirmButtonText: confirm);
  return Navigator.of(
    context,
  ).push<String>(FileManagerPage.route(start ?? AppScope.read(context).config.gameDir, pick: true, confirm: confirm));
}

/// 手机上的下载目录（找不到时用存储根目录）
String get mobileDownloadDir {
  final d = p.join(AndroidStorage.root, 'Download');
  return Directory(d).existsSync() ? d : AndroidStorage.root;
}

/// 选择一个文件：桌面端用系统对话框，手机上用内置的文件管理器。
/// [extensions] 不带点，例如 `['mrpack']`；为空时不限制。选图片仍然用系统相册（各页面自己处理）。
Future<String?> pickFile(
  BuildContext context, {
  String? start,
  List<String>? extensions,
  String label = '文件',
  String confirm = '选择',
}) async {
  if (isDesktop) {
    final f = await openFile(
      acceptedTypeGroups: [
        if (extensions != null && extensions.isNotEmpty) XTypeGroup(label: label, extensions: extensions),
      ],
      confirmButtonText: confirm,
    );
    return f?.path;
  }
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) => FileManagerPage(
        start: start ?? mobileDownloadDir,
        mode: FilePickMode.file,
        extensions: extensions,
        confirm: confirm,
        label: label,
      ),
    ),
  );
}

/// 选择保存位置：桌面端用系统对话框，手机上用内置的文件管理器（选文件夹并填写文件名）
Future<String?> pickSavePath(
  BuildContext context,
  String name, {
  String? start,
  List<String>? extensions,
  String label = '文件',
}) async {
  if (isDesktop) {
    final loc = await getSaveLocation(
      suggestedName: name,
      confirmButtonText: '保存',
      acceptedTypeGroups: [
        if (extensions != null && extensions.isNotEmpty) XTypeGroup(label: label, extensions: extensions),
      ],
    );
    return loc?.path;
  }
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) =>
          FileManagerPage(start: start ?? mobileDownloadDir, mode: FilePickMode.save, saveName: name, label: label),
    ),
  );
}

/// 文件管理器的用途：浏览管理，或者为其他功能选择文件夹、文件、保存位置
enum FilePickMode { none, folder, file, save }

final _textFile = RegExp(
  r'\.(txt|log|json|json5|toml|properties|cfg|conf|ini|yml|yaml|mcmeta|snbt|md|csv|xml)$',
  caseSensitive: false,
);
final _imageFile = RegExp(r'\.(png|jpe?g|webp|gif|bmp)$', caseSensitive: false);

/// 手机上要求「文件」页打开某个位置：主界面切到「文件」页，文件管理器打开这个路径（文件则打开所在文件夹并标出它）
final fileManagerRequest = ValueNotifier<String?>(null);

/// 主界面里的「文件」页
class EmbeddedFileManager extends StatelessWidget {
  const EmbeddedFileManager({super.key});

  @override
  Widget build(BuildContext context) => FileManagerPage(start: AppScope.of(context).config.gameDir, embedded: true);
}

/// 手机上的内置文件管理器：浏览、新建、重命名、复制 / 剪切 / 粘贴、删除到回收站、从手机导入文件。
/// [pick] 为 true 时用来选择文件夹，返回选中的路径。
class FileManagerPage extends StatefulWidget {
  const FileManagerPage({
    super.key,
    required this.start,
    bool pick = false,
    FilePickMode? mode,
    this.confirm = '选择',
    this.extensions,
    this.saveName,
    this.label = '文件',
    this.embedded = false,
  }) : mode = mode ?? (pick ? FilePickMode.folder : FilePickMode.none);

  /// 嵌在主界面的「文件」页里：不带标题栏，常用位置显示为左侧二级菜单
  final bool embedded;

  final String start;
  final FilePickMode mode;
  final String confirm;

  /// 选择文件时只能选这些扩展名（不带点）；为空时不限制
  final List<String>? extensions;

  /// 选择保存位置时预填的文件名
  final String? saveName;
  final String label;

  bool get pick => mode != FilePickMode.none;

  static Route<String> route(String start, {bool pick = false, String confirm = '选择'}) => MaterialPageRoute(
    builder: (_) => FileManagerPage(start: start, pick: pick, confirm: confirm),
  );

  @override
  State<FileManagerPage> createState() => _FileManagerPageState();
}

/// 复制 / 剪切的内容，在多次打开文件管理器之间保留
({List<String> paths, bool cut})? _clipboard;

class _FileManagerPageState extends State<FileManagerPage> {
  static const _rowHeight = 60.0;

  late String _dir;
  String? _highlight;
  final _history = <String>[];
  List<FileSystemEntity> _entries = [];
  Object? _error;
  bool _needAccess = false;
  String? _busy;
  late ScrollController _scroll = ScrollController();
  late final _saveName = TextEditingController(text: widget.saveName ?? '');

  /// 选择文件时，这个文件能不能选
  bool _selectable(String name) {
    final ext = widget.extensions;
    if (ext == null || ext.isEmpty) return true;
    final lower = name.toLowerCase();
    return ext.any((e) => lower.endsWith('.${e.toLowerCase()}'));
  }

  Future<void> _confirmSave() async {
    final name = _saveName.text.trim();
    if (name.isEmpty || name.contains('/') || name.contains(r'\')) {
      toast(context, '请填写有效的文件名');
      return;
    }
    final target = p.join(_dir, name);
    if (FileSystemEntity.isDirectorySync(target)) {
      toast(context, '已经有同名的文件夹');
      return;
    }
    if (File(target).existsSync()) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('替换已有的文件？'),
          content: Text('这个文件夹里已经有「$name」，保存后会替换它。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('替换')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    Navigator.pop(context, target);
  }

  @override
  void initState() {
    super.initState();
    // 打开的是文件时显示它所在的文件夹，并标出这个文件
    if (FileSystemEntity.isFileSync(widget.start)) {
      _dir = p.dirname(widget.start);
      _highlight = widget.start;
    } else {
      _dir = widget.start;
    }
    _load();
    if (widget.embedded) {
      fileManagerRequest.addListener(_onRequest);
      _onRequest();
    }
  }

  /// 别的页面要求打开某个位置（见 [fileManagerRequest]）
  void _onRequest() {
    final path = fileManagerRequest.value;
    if (path == null) return;
    fileManagerRequest.value = null;
    if (FileSystemEntity.isFileSync(path)) {
      _open(p.dirname(path));
      _highlight = path;
    } else {
      _open(path);
    }
  }

  @override
  void dispose() {
    fileManagerRequest.removeListener(_onRequest);
    _scroll.dispose();
    _saveName.dispose();
    super.dispose();
  }

  bool get _inTrash => [
    p.join(Paths.appData, 'trash'),
    p.join(AndroidStorage.launcherDir, '.trash'),
  ].any((t) => p.equals(t, _dir) || p.isWithin(t, _dir));

  Future<void> _load() async {
    List<FileSystemEntity> list;
    Object? error;
    var needAccess = false;
    try {
      await Directory(_dir).create(recursive: true);
      list = Directory(_dir).listSync(followLinks: false);
      list.sort((a, b) {
        final da = a is Directory, db = b is Directory;
        if (da != db) return da ? -1 : 1;
        return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
      });
    } catch (e) {
      list = [];
      error = e;
      needAccess = AndroidStorage.isShared(_dir) && !await AndroidStorage.hasAccess();
    }
    if (!mounted) return;
    final index = _highlight == null ? -1 : list.indexWhere((e) => p.equals(e.path, _highlight!));
    _scroll.dispose();
    _scroll = ScrollController(initialScrollOffset: index > 2 ? (index - 2) * _rowHeight : 0);
    setState(() {
      _entries = list;
      _error = error;
      _needAccess = needAccess;
    });
  }

  void _open(String dir, {bool remember = true}) {
    if (remember) _history.add(_dir);
    _dir = p.normalize(dir);
    _highlight = null;
    _load();
  }

  void _up() {
    final parent = p.dirname(_dir);
    if (parent != _dir) _open(parent);
  }

  /// 返回键先回到上一个文件夹
  bool _back() {
    if (_history.isEmpty) return false;
    _open(_history.removeLast(), remember: false);
    return true;
  }

  Future<void> _run(String label, Future<void> Function() job) async {
    setState(() => _busy = label);
    try {
      await job();
    } catch (e) {
      if (mounted) toast(context, '$label失败：${errorText(e)}');
    }
    if (!mounted) return;
    setState(() => _busy = null);
    await _load();
  }

  Future<String?> _askName(String title, {String initial = ''}) {
    final ctrl = TextEditingController(text: initial);
    final ext = p.extension(initial);
    ctrl.selection = TextSelection(baseOffset: 0, extentOffset: initial.length - ext.length);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '名称'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text('确定')),
        ],
      ),
    );
  }

  String? _checkName(String? name) {
    name = name?.trim();
    if (name == null || name.isEmpty) return null;
    if (name.contains('/') || name.contains('\\') || name == '.' || name == '..') {
      toast(context, '名称不能包含 / 或 \\');
      return null;
    }
    return name;
  }

  Future<void> _newFolder() async {
    final raw = await _askName('新建文件夹');
    if (!mounted) return;
    final name = _checkName(raw);
    if (name == null) return;
    final target = p.join(_dir, name);
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) return toast(context, '已有同名的文件或文件夹');
    _highlight = target;
    await _run('新建文件夹', () => Directory(target).create());
  }

  Future<void> _rename(FileSystemEntity e) async {
    final raw = await _askName('重命名', initial: p.basename(e.path));
    if (!mounted) return;
    final name = _checkName(raw);
    if (name == null || name == p.basename(e.path)) return;
    final target = p.join(_dir, name);
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) return toast(context, '已有同名的文件或文件夹');
    _highlight = target;
    await _run('重命名', () => e.rename(target));
  }

  Future<void> _delete(FileSystemEntity e) async {
    final name = p.basename(e.path);
    if (_inTrash) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('彻底删除'),
          content: Text('「$name」会被彻底删除，不能恢复。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('彻底删除')),
          ],
        ),
      );
      if (ok == true) await _run('删除', () => e.delete(recursive: true));
      return;
    }
    await _run('删除', () => moveToTrash(e.path));
    if (mounted) toast(context, '「$name」已移到回收站');
  }

  Future<void> _paste() async {
    final clip = _clipboard;
    if (clip == null) return;
    for (final src in clip.paths) {
      if (p.equals(src, _dir) || p.isWithin(src, _dir)) return toast(context, '不能把文件夹粘贴到它自己里面');
    }
    final total = clip.paths.fold(0, (n, s) => n + countFiles(s));
    var done = 0;
    void tick(String _) {
      done++;
      if (mounted && done % 20 == 0) setState(() => _busy = '正在粘贴（$done / $total）');
    }

    await _run(clip.cut ? '移动' : '复制', () async {
      for (final src in clip.paths) {
        final target = uniquePath(p.join(_dir, p.basename(src)));
        if (clip.cut && p.equals(p.dirname(src), _dir)) continue;
        _highlight = target;
        await (clip.cut ? moveEntity(src, target, onFile: tick) : copyEntity(src, target, onFile: tick));
      }
      if (clip.cut) _clipboard = null;
    });
  }

  Future<void> _import() async {
    final files = await openFiles(confirmButtonText: '导入');
    if (files.isEmpty) return;
    await _run('导入', () async {
      for (final f in files) {
        final target = uniquePath(p.join(_dir, f.name));
        await f.saveTo(target);
        _highlight = target;
      }
    });
    if (mounted) toast(context, '已导入 ${files.length} 个文件');
  }

  Future<void> _requestAccess() async {
    await AndroidStorage.requestAccess();
    await _load();
  }

  void _openFile(File f) {
    final name = p.basename(f.path);
    if (_imageFile.hasMatch(name)) {
      showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: InteractiveViewer(child: Image.file(f, fit: BoxFit.contain)),
        ),
      );
    } else if (_textFile.hasMatch(name)) {
      String text;
      try {
        final raf = f.openSync();
        final bytes = raf.readSync(512 * 1024);
        raf.closeSync();
        text = utf8.decode(bytes, allowMalformed: true);
        if (f.lengthSync() > bytes.length) text += '\n\n…（文件较大，只显示前 512 KB）';
      } catch (e) {
        text = '无法读取：${errorText(e)}';
      }
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(name, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: 760,
            height: 420,
            child: SingleChildScrollView(
              child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
        ),
      );
    } else {
      toast(context, '不能预览这种文件。可以复制、剪切、重命名或删除');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = AppScope.of(context);
    final shortcuts = [
      (icon: Icons.sports_esports_outlined, label: '游戏文件夹', path: state.config.gameDir),
      if (Platform.isAndroid) (icon: Icons.smartphone, label: '手机存储', path: AndroidStorage.root),
      (icon: Icons.inventory_2_outlined, label: '应用数据', path: Paths.appData),
      (icon: Icons.delete_outline, label: '回收站', path: mobileTrashFor(state.config.gameDir)),
    ];
    final clip = _clipboard;
    final actions = [
      IconButton(tooltip: '上一级', onPressed: _up, icon: const Icon(Icons.arrow_upward)),
      IconButton(tooltip: '新建文件夹', onPressed: _newFolder, icon: const Icon(Icons.create_new_folder_outlined)),
      if (!widget.pick)
        IconButton(tooltip: '从手机导入文件', onPressed: _import, icon: const Icon(Icons.file_upload_outlined)),
      IconButton(tooltip: '刷新', onPressed: _load, icon: const Icon(Icons.refresh)),
      const SizedBox(width: 8),
    ];
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 嵌在主界面里时，常用位置放在左侧的二级菜单
        if (!widget.embedded)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final s in shortcuts)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      avatar: Icon(s.icon, size: 18),
                      label: Text(s.label),
                      onPressed: () => _open(s.path),
                    ),
                  ),
              ],
            ),
          ),
        _Breadcrumbs(path: _dir, onOpen: _open),
        if (_busy != null) ...[const LinearProgressIndicator(), _Banner(text: _busy!)],
        if (clip != null)
          Material(
            color: scheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: [
                  Icon(clip.cut ? Icons.content_cut : Icons.content_copy, size: 18),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '已${clip.cut ? '剪切' : '复制'}「${p.basename(clip.paths.first)}」'
                      '${clip.paths.length > 1 ? ' 等 ${clip.paths.length} 项' : ''}，打开目标文件夹后粘贴',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(onPressed: () => setState(() => _clipboard = null), child: const Text('取消')),
                  FilledButton.tonalIcon(
                    onPressed: _busy == null ? _paste : null,
                    icon: const Icon(Icons.content_paste),
                    label: const Text('粘贴到这里'),
                  ),
                ],
              ),
            ),
          ),
        Expanded(child: _body(theme)),
        if (widget.mode == FilePickMode.folder)
          Material(
            color: scheme.surfaceContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
              child: Row(
                children: [
                  Expanded(child: Text(_dir, overflow: TextOverflow.ellipsis)),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _error == null ? () => Navigator.pop(context, _dir) : null,
                    child: Text('${widget.confirm}这个文件夹'),
                  ),
                ],
              ),
            ),
          ),
        if (widget.mode == FilePickMode.file)
          Material(
            color: scheme.surfaceContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.extensions == null || widget.extensions!.isEmpty
                          ? '点一个文件来${widget.confirm}'
                          : '点一个 ${widget.extensions!.map((e) => '.$e').join(' / ')} 文件来${widget.confirm}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                ],
              ),
            ),
          ),
        if (widget.mode == FilePickMode.save)
          Material(
            color: scheme.surfaceContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _saveName,
                      decoration: const InputDecoration(labelText: '文件名', isDense: true, border: OutlineInputBorder()),
                      onSubmitted: (_) => _confirmSave(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                  FilledButton(onPressed: _error == null ? _confirmSave : null, child: const Text('保存到这里')),
                ],
              ),
            ),
          ),
      ],
    );

    if (widget.embedded) {
      // 当前所在的常用位置（最具体的那一个），在二级菜单里高亮
      String? current;
      for (final s in shortcuts) {
        if ((p.equals(s.path, _dir) || p.isWithin(s.path, _dir)) &&
            (current == null || s.path.length > current.length)) {
          current = s.path;
        }
      }
      return PopScope(
        // 返回键先回到上一个文件夹，没有可返回的再交给系统
        canPop: _history.isEmpty,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _back();
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SideNav<String?>(
              groups: [
                SideNavGroup('位置', [for (final s in shortcuts) SideNavItem<String?>(s.path, s.label, s.icon)]),
              ],
              value: current,
              onChanged: (v) {
                if (v != null) _open(v);
              },
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            p.basename(_dir).isEmpty ? _dir : p.basename(_dir),
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        ...actions,
                      ],
                    ),
                  ),
                  Expanded(child: content),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_back()) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(switch (widget.mode) {
            FilePickMode.folder => '选择文件夹',
            FilePickMode.file => '选择${widget.label}',
            FilePickMode.save => '保存${widget.label}',
            FilePickMode.none => '文件管理',
          }),
          actions: actions,
        ),
        body: content,
      ),
    );
  }

  Widget _body(ThemeData theme) {
    final scheme = theme.colorScheme;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_needAccess ? Icons.lock_outline : Icons.error_outline, size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                _needAccess ? '需要「所有文件访问权限」才能访问手机存储' : '无法打开这个文件夹：${errorText(_error!)}',
                textAlign: TextAlign.center,
              ),
              if (_needAccess) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: _requestAccess, child: const Text('去授予权限')),
              ],
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text('空文件夹', style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView.builder(
      controller: _scroll,
      itemExtent: _rowHeight,
      itemCount: _entries.length,
      itemBuilder: (context, i) {
        final e = _entries[i];
        final isDir = e is Directory;
        final name = p.basename(e.path);
        FileStat? stat;
        try {
          stat = e.statSync();
        } catch (_) {
          // 文件刚被删除
        }
        final info = [
          if (stat != null) formatDate(stat.modified),
          if (stat != null && !isDir) formatSize(stat.size),
        ].join(' · ');
        // 选择文件时：不符合的文件变灰、不能点；保存时点文件等于用它的名字
        final pickingFile = widget.mode == FilePickMode.file;
        final enabled = isDir || !pickingFile || _selectable(name);
        return ListTile(
          enabled: enabled,
          selected: _highlight != null && p.equals(e.path, _highlight!),
          selectedTileColor: scheme.secondaryContainer,
          leading: Icon(
            isDir
                ? Icons.folder
                : _imageFile.hasMatch(name)
                ? Icons.image_outlined
                : _textFile.hasMatch(name)
                ? Icons.description_outlined
                : Icons.insert_drive_file_outlined,
            color: isDir ? scheme.primary : scheme.onSurfaceVariant,
          ),
          title: Text(name, overflow: TextOverflow.ellipsis),
          subtitle: Text(info),
          onTap: () {
            if (isDir) return _open(e.path);
            if (pickingFile) return Navigator.pop(context, e.path);
            if (widget.mode == FilePickMode.save) return setState(() => _saveName.text = name);
            _openFile(e as File);
          },
          trailing: widget.pick
              ? null
              : PopupMenuButton<String>(
                  tooltip: '更多操作',
                  onSelected: (v) => switch (v) {
                    'copy' => setState(() => _clipboard = (paths: [e.path], cut: false)),
                    'cut' => setState(() => _clipboard = (paths: [e.path], cut: true)),
                    'rename' => _rename(e),
                    'delete' => _delete(e),
                    _ => null,
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'copy', child: Text('复制')),
                    const PopupMenuItem(value: 'cut', child: Text('剪切')),
                    const PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'delete', child: Text(_inTrash ? '彻底删除' : '删除')),
                  ],
                ),
        );
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}

/// 路径的每一级都可以点击
class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.path, required this.onOpen});

  final String path;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final parts = p.split(path);
    final crumbs = <({String label, String path})>[];
    for (var i = 0; i < parts.length; i++) {
      crumbs.add((label: parts[i], path: p.joinAll(parts.take(i + 1))));
    }
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: crumbs.length,
        separatorBuilder: (_, _) => Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
        itemBuilder: (context, i) {
          final c = crumbs[crumbs.length - 1 - i];
          return TextButton(onPressed: i == 0 ? null : () => onOpen(c.path), child: Text(c.label));
        },
      ),
    );
  }
}
