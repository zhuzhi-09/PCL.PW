import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_info.dart';
import '../app_scope.dart';
import '../app_state.dart';
import '../core/android_runtime.dart';
import '../core/instance.dart';
import '../core/instance_config.dart';
import '../core/instance_files.dart';
import '../core/loader_names.dart';
import '../core/recent_worlds.dart';
import '../core/site_api.dart';
import '../core/updater.dart';
import '../platform.dart';
import '../shell.dart';
import '../widgets/cover_palette.dart';
import '../widgets/launch_dialogs.dart';
import '../widgets/version_icon.dart';
import 'download_page.dart';
import 'home_feed.dart';

/// 启动页：左边是当前版本（背景取自存档封面的颜色），右边是公告和常用操作，下面是最近游玩。
/// 左右分界线对齐顶栏「后台任务」的右边缘。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Future<List<RecentWorld>>? _worlds;
  String? _worldsKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final config = state.config;
    final key = [
      config.gameDir,
      for (final folder in config.gameFolders) folder.path,
      state.gameState.index,
    ].join('\u0000');
    if (_worldsKey == key) return;
    final first = _worlds == null;
    _worldsKey = key;
    _worlds = recentWorlds(config, force: !first);
  }

  Future<void> _launch() async {
    final state = AppScope.read(context);
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

  Future<void> _playWorld(RecentWorld world) async {
    final state = AppScope.read(context);
    final versionId = world.versionId;
    if (versionId != null && versionId.isNotEmpty && state.selectedVersion?.id != versionId) {
      await state.selectVersion(versionId);
    }
    if (mounted) await _launch();
  }

  void _openInstance() {
    final version = AppScope.read(context).selectedVersion;
    if (version == null) return;
    AppScope.read(context).instanceId = version.id;
    ShellNav.of(context).open(SubPage.instance);
  }

  Future<void> _openFolder() async {
    final state = AppScope.read(context);
    final version = state.selectedVersion;
    if (version == null) return;
    try {
      await openInFileManager(await state.gameDirOf(version));
    } catch (e) {
      if (mounted) toast(context, '打不开文件夹：${errorText(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    final version = state.selectedVersion;

    return FutureBuilder<List<RecentWorld>>(
      future: _worlds,
      builder: (context, snap) {
        final worlds = snap.data ?? const <RecentWorld>[];
        final latest = version == null ? null : worlds.where((w) => w.versionId == version.id).firstOrNull;
        if (isDesktop) {
          return _DesktopHome(
            state: state,
            version: version,
            latest: latest,
            worlds: worlds,
            loading: snap.connectionState == ConnectionState.waiting && worlds.isEmpty,
            onLaunch: _launch,
            onVersions: () => ShellNav.of(context).open(SubPage.versions),
            onSettings: version == null ? null : _openInstance,
            onLog: () => ShellNav.of(context).open(SubPage.log),
            onFolder: version == null ? null : _openFolder,
            onInstallMods: () {
              downloadTabRequest.value = 'mods';
              ShellNav.of(context).goMain(MainPage.download);
            },
            onPlayWorld: _playWorld,
            versionName: (id) => _versionName(state, id),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(14, 0, 16, 16),
          children: [
            SizedBox(
              height: 176,
              child: AlignedSplit(
                left: _HeroCard(
                  state: state,
                  version: version,
                  latest: latest,
                  onLaunch: _launch,
                  onVersions: () => ShellNav.of(context).open(SubPage.versions),
                  onSettings: version == null ? null : _openInstance,
                  onLog: () => ShellNav.of(context).open(SubPage.log),
                  onFolder: version == null ? null : _openFolder,
                ),
                right: _SidePanel(
                  onInstallMods: () {
                    downloadTabRequest.value = 'mods';
                    ShellNav.of(context).goMain(MainPage.download);
                  },
                  onManageMods: version == null ? null : _openInstance,
                  onFolder: version == null ? null : _openFolder,
                  onLog: () => ShellNav.of(context).open(SubPage.log),
                ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 36,
              child: Row(
                children: [
                  Text('最近游玩', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  TextButton(onPressed: version == null ? null : _openInstance, child: const Text('全部存档 ›')),
                ],
              ),
            ),
            if (snap.connectionState == ConnectionState.waiting && worlds.isEmpty)
              const SizedBox(height: _WorldCard.height)
            else if (worlds.isEmpty)
              const _EmptyWorlds()
            else
              SizedBox(
                height: _WorldCard.height,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: worlds.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, i) => _WorldCard(
                    world: worlds[i],
                    versionName: _versionName(state, worlds[i].versionId),
                    onTap: worlds[i].versionId == null ? null : () => state.selectVersion(worlds[i].versionId!),
                    onPlay: () => _playWorld(worlds[i]),
                  ),
                ),
              ),
            if (state.config.homeHints) ...[const SizedBox(height: 20), const HomeHints()],
            const ChangelogHint(),
            if (state.config.homeNews) ...[const SizedBox(height: 18), const VersionNewsFeed()],
          ],
        );
      },
    );
  }

  static String _versionName(AppState state, String? id) {
    if (id == null) return '';
    final v = state.versions.where((v) => v.id == id).firstOrNull;
    return v == null ? id : versionTitle(v);
  }
}

String _timeAgo(DateTime time) {
  final d = DateTime.now().difference(time);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  if (d.inDays < 30) return '${d.inDays} 天前';
  return '${time.month}月${time.day}日';
}

/// 当前版本：背景是这个版本最近存档封面的主色，右上角是封面小图
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.state,
    required this.version,
    required this.latest,
    required this.onLaunch,
    required this.onVersions,
    required this.onSettings,
    required this.onLog,
    required this.onFolder,
  });

  final AppState state;
  final InstanceInfo? version;
  final RecentWorld? latest;
  final VoidCallback onLaunch;
  final VoidCallback onVersions;
  final VoidCallback? onSettings;
  final VoidCallback onLog;
  final VoidCallback? onFolder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = version;
    // 背景色：有自定义版本图标时从图标取色，否则用主题色（不再用存档封面）
    final versionDir = v == null ? null : state.paths.versionDir(v.id);
    final logo = versionDir == null ? null : customVersionLogo(versionDir);
    const white = Colors.white;
    return CoverBackground(
      iconPath: logo,
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        children: [
          // 均匀压暗，封面颜色很亮时白色文字也清楚
          Positioned.fill(child: ColoredBox(color: Colors.black.withValues(alpha: .28))),
          if (v != null)
            Positioned(
              right: 16,
              top: 16,
              child: VersionIcon(info: v, versionDir: versionDir!, size: 64, radius: 14),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Material(
                  color: Colors.white.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    onTap: onVersions,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '切换版本',
                            style: theme.textTheme.labelMedium?.copyWith(color: white.withValues(alpha: .8)),
                          ),
                          Icon(Icons.expand_more, size: 16, color: white.withValues(alpha: .8)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: EdgeInsets.only(right: v == null ? 0 : 76),
                  child: Text(
                    v == null ? '还没有选择版本' : versionTitle(v),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.headlineSmall?.copyWith(color: white, fontWeight: FontWeight.w800),
                  ),
                ),
                if (v != null && versionTitle(v) != v.id)
                  Padding(
                    padding: const EdgeInsets.only(right: 76),
                    child: Text(
                      v.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: white.withValues(alpha: .5),
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
                if (v == null)
                  Text(
                    '先下载或选择一个版本，准备好就开始',
                    style: theme.textTheme.bodySmall?.copyWith(color: white.withValues(alpha: .75)),
                  )
                else
                  _VersionFacts(state: state, version: v, latest: latest),
                const Spacer(),
                Row(
                  children: [
                    _LaunchButton(state: state, version: v, onLaunch: onLaunch),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: onSettings,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: white,
                        side: BorderSide(color: white.withValues(alpha: .25)),
                        backgroundColor: Colors.black.withValues(alpha: .18),
                        minimumSize: const Size(0, 44),
                      ),
                      icon: const Icon(Icons.tune, size: 18),
                      label: const Text('版本设置'),
                    ),
                    const SizedBox(width: 8),
                    PopupMenuButton<String>(
                      tooltip: '更多',
                      onSelected: (value) {
                        if (value == 'versions') onVersions();
                        if (value == 'log') onLog();
                        if (value == 'folder') onFolder?.call();
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(value: 'versions', child: Text('版本选择')),
                        PopupMenuItem(value: 'folder', enabled: onFolder != null, child: const Text('打开版本文件夹')),
                        const PopupMenuItem(value: 'log', child: Text('游戏日志')),
                      ],
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .18),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: white.withValues(alpha: .25)),
                        ),
                        child: const Icon(Icons.more_horiz, color: white),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 「12 个模组 · Zink 渲染 · 14 小时前玩过」
/// 版本 mods 文件夹里的 jar 数量；读不到时为 null
Future<int?> _modCount(AppState state, InstanceInfo version) async {
  try {
    final dir = Directory(p.join(await state.gameDirOf(version), 'mods'));
    if (!dir.existsSync()) return 0;
    return dir.listSync().where((e) => e is File && e.path.toLowerCase().endsWith('.jar')).length;
  } catch (_) {
    return null;
  }
}

class _VersionFacts extends StatelessWidget {
  const _VersionFacts({required this.state, required this.version, required this.latest, this.color});

  final AppState state;
  final InstanceInfo version;
  final RecentWorld? latest;

  /// 默认是压在封面色上的半透明白字
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String? renderer;
    if (Platform.isAndroid) {
      final inst = readInstanceSettings(state.paths.versionDir(version.id)).renderer;
      final pref = inst.isNotEmpty ? inst : state.config.androidRenderer;
      if (pref != 'auto') renderer = androidRenderers[pref]?.split('（').first;
    }
    return FutureBuilder<int?>(
      future: version.loader == Loader.vanilla ? Future.value(null) : _modCount(state, version),
      builder: (context, snap) {
        final parts = [
          if (snap.data != null) '${snap.data} 个模组',
          ?renderer == null ? null : '$renderer 渲染',
          if (latest != null) '${_timeAgo(latest!.modified)}玩过',
          if (snap.data == null && renderer == null && latest == null) describeVersion(version),
        ];
        return Text(
          parts.join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: color ?? Colors.white.withValues(alpha: .78)),
        );
      },
    );
  }
}

class _LaunchButton extends StatelessWidget {
  const _LaunchButton({required this.state, required this.version, required this.onLaunch});

  final AppState state;
  final InstanceInfo? version;
  final VoidCallback onLaunch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (state.gameState == GameState.preparing && state.task != null) {
      return ListenableBuilder(
        listenable: state.task!,
        builder: (context, _) {
          final t = state.task!;
          return Container(
            width: 190,
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .14),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  t.total > 0 ? '${t.stage} · ${t.countText}' : t.stage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 5),
                LinearProgressIndicator(
                  value: t.fraction,
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(4),
                  color: scheme.primaryFixed,
                  backgroundColor: Colors.white.withValues(alpha: .18),
                ),
              ],
            ),
          );
        },
      );
    }

    final running = state.gameState == GameState.running;
    if (running && !isDesktop) {
      return Row(
        children: [
          FilledButton.icon(
            onPressed: state.resumeGame,
            style: FilledButton.styleFrom(minimumSize: const Size(130, 44)),
            icon: const Icon(Icons.sports_esports, size: 19),
            label: const Text('返回游戏'),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: '结束游戏',
            onPressed: state.killGame,
            style: IconButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
              minimumSize: const Size(44, 44),
            ),
            icon: const Icon(Icons.stop, size: 19),
          ),
        ],
      );
    }

    return FilledButton.icon(
      onPressed: running ? state.killGame : (version == null ? null : onLaunch),
      style: FilledButton.styleFrom(
        backgroundColor: running ? scheme.error : scheme.primaryFixed,
        foregroundColor: running ? scheme.onError : scheme.onPrimaryFixed,
        disabledBackgroundColor: Colors.white.withValues(alpha: .2),
        disabledForegroundColor: Colors.white.withValues(alpha: .6),
        minimumSize: const Size(132, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        textStyle: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      icon: Icon(running ? Icons.stop : Icons.rocket_launch, size: 19),
      label: Text(running ? '结束游戏' : '开始游戏'),
    );
  }
}

/// 右半边：启动器公告 + 2×2 常用操作（跟当前版本相关）
class _SidePanel extends StatelessWidget {
  const _SidePanel({
    required this.onInstallMods,
    required this.onManageMods,
    required this.onFolder,
    required this.onLog,
  });

  final VoidCallback onInstallMods;
  final VoidCallback? onManageMods;
  final VoidCallback? onFolder;
  final VoidCallback onLog;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _NoticeStrip(),
          const SizedBox(height: 8),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _QuickButton(icon: Icons.download_outlined, label: '装模组', onTap: onInstallMods),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _QuickButton(icon: Icons.view_list_outlined, label: '管理模组', onTap: onManageMods),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _QuickButton(icon: Icons.folder_outlined, label: '文件夹', onTap: onFolder),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _QuickButton(icon: Icons.article_outlined, label: '查看日志', onTap: onLog),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickButton extends StatelessWidget {
  const _QuickButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onTap != null;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(icon, size: 19, color: enabled ? scheme.primary : scheme.onSurfaceVariant.withValues(alpha: .5)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: enabled ? null : scheme.onSurfaceVariant.withValues(alpha: .5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 启动器公告（notices.json）里当前可见的第一条，标题和「查看」同一行，内容最多两行
class _NoticeStrip extends StatefulWidget {
  const _NoticeStrip({this.neutral = false});

  /// 桌面：和其他卡片一样的中性底色，主色只用在小图标上，内容可以多显示几行
  final bool neutral;

  @override
  State<_NoticeStrip> createState() => _NoticeStripState();
}

class _NoticeStripState extends State<_NoticeStrip> {
  final _future = loadNotices();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cfg = AppScope.of(context).config;
    return FutureBuilder<List<Notice>>(
      future: _future,
      builder: (context, snap) {
        final notice = (snap.data ?? const <Notice>[])
            .where(
              (n) => n.visibleFor(
                platform: noticePlatform,
                channel: UpdateChannel.parse(cfg.updateChannel).name,
                version: AppInfo.version,
                now: DateTime.now(),
                dismissed: const {},
              ),
            )
            .firstOrNull;
        final title = notice?.title ?? '启动器公告';
        final body = notice == null
            ? (snap.connectionState == ConnectionState.waiting ? '正在获取…' : '暂无公告')
            : notice.body.replaceAll(RegExp(r'[#*_`>\[\]]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
        if (widget.neutral) return _neutral(context, title, body);
        return Material(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => showNoticesDialog(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        '查看 ›',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onPrimaryContainer.withValues(alpha: .8),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body.isEmpty ? title : body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

extension on _NoticeStripState {
  Widget _neutral(BuildContext context, String title, String body) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showNoticesDialog(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.campaign_outlined, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text('查看 ›', style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary)),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Text(
                  body.isEmpty ? title : body,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 最近游玩：上半部分是封面主色 + 居中的清晰小封面，下半部分是名称和版本
class _WorldCard extends StatelessWidget {
  const _WorldCard({required this.world, required this.versionName, required this.onTap, required this.onPlay});

  final RecentWorld world;
  final String versionName;
  final VoidCallback? onTap;
  final VoidCallback onPlay;

  static const height = 124.0;
  static const width = 196.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = p.join(world.path, 'icon.png');
    return SizedBox(
      width: width,
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 68,
                    child: CoverBackground(
                      iconPath: icon,
                      child: Center(
                        child: CoverThumb(iconPath: icon, size: 54, radius: 9, modified: world.modified),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 7, 10, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          world.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          [if (versionName.isNotEmpty) versionName, _timeAgo(world.modified)].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Positioned(
                right: 8,
                top: 46,
                child: IconButton.filled(
                  tooltip: '进入这个存档的版本',
                  onPressed: onPlay,
                  style: IconButton.styleFrom(minimumSize: const Size(40, 40), fixedSize: const Size(40, 40)),
                  icon: const Icon(Icons.rocket_launch, size: 19),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyWorlds extends StatelessWidget {
  const _EmptyWorlds();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(Icons.landscape_outlined, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '开始一次游戏后，最近的存档会出现在这里。',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 桌面首页：第一屏正好铺满窗口，只放最常用的（当前版本、公告与常用操作、最近游玩）；
// 版本动态、当前版本信息和提示放在往下滚的部分。手机仍用上面的布局。
// ---------------------------------------------------------------------------

class _DesktopHome extends StatefulWidget {
  const _DesktopHome({
    required this.state,
    required this.version,
    required this.latest,
    required this.worlds,
    required this.loading,
    required this.onLaunch,
    required this.onVersions,
    required this.onSettings,
    required this.onLog,
    required this.onFolder,
    required this.onInstallMods,
    required this.onPlayWorld,
    required this.versionName,
  });

  final AppState state;
  final InstanceInfo? version;
  final RecentWorld? latest;
  final List<RecentWorld> worlds;
  final bool loading;
  final VoidCallback onLaunch;
  final VoidCallback onVersions;
  final VoidCallback? onSettings;
  final VoidCallback onLog;
  final VoidCallback? onFolder;
  final VoidCallback onInstallMods;
  final Future<void> Function(RecentWorld) onPlayWorld;
  final String Function(String?) versionName;

  @override
  State<_DesktopHome> createState() => _DesktopHomeState();
}

class _DesktopHomeState extends State<_DesktopHome> {
  final _scroll = ScrollController();

  static const _pad = EdgeInsets.fromLTRB(14, 0, 16, 0);
  static const _gap = 14.0;
  static const _headerH = 36.0;
  static const _moreH = 34.0;
  static const _tileH = 64.0;
  static const _tileGap = 10.0;
  static const _tileMinW = 230.0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cfg = widget.state.config;
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth - _pad.horizontal;
        // 最近游玩：按宽度算列数，最多两行；第二行没排满就空着
        final cols = math.max(1, ((width + _tileGap) / (_tileMinW + _tileGap)).floor());
        final rows = widget.worlds.isEmpty ? 1 : math.min(2, (widget.worlds.length / cols).ceil());
        final shown = widget.worlds.take(cols * rows).toList();
        final tileW = (width - _tileGap * (cols - 1)) / cols;
        final worldsH = widget.worlds.isEmpty ? 72.0 : rows * _tileH + (rows - 1) * _tileGap;
        // 第一屏高度 = 可见高度；主卡片那一行吃掉剩余高度，但有上下限，超出部分让内容整体垂直居中
        final foldH = math.max(box.maxHeight, 430.0);
        final topH = (foldH - _headerH - worldsH - _moreH - _gap * 2 - 16).clamp(176.0, foldH > 820 ? 380.0 : 340.0);
        return ListView(
          controller: _scroll,
          padding: _pad,
          children: [
            SizedBox(
              height: foldH,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: topH,
                    child: AlignedSplit(
                      gap: 12,
                      left: _DesktopHero(
                        state: widget.state,
                        version: widget.version,
                        latest: widget.latest,
                        onLaunch: widget.onLaunch,
                        onVersions: widget.onVersions,
                        onSettings: widget.onSettings,
                        onLog: widget.onLog,
                        onFolder: widget.onFolder,
                      ),
                      right: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Expanded(child: _NoticeStrip(neutral: true)),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 106,
                            child: Column(
                              children: [
                                Expanded(
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(
                                        child: _QuickButton(
                                          icon: Icons.download_outlined,
                                          label: '装模组',
                                          onTap: widget.onInstallMods,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _QuickButton(
                                          icon: Icons.view_list_outlined,
                                          label: '管理模组',
                                          onTap: widget.onSettings,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Expanded(
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(
                                        child: _QuickButton(
                                          icon: Icons.folder_outlined,
                                          label: '文件夹',
                                          onTap: widget.onFolder,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _QuickButton(
                                          icon: Icons.article_outlined,
                                          label: '查看日志',
                                          onTap: widget.onLog,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: _gap),
                  SizedBox(
                    height: _headerH,
                    child: Row(
                      children: [
                        Text('最近游玩', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                        const Spacer(),
                        TextButton(onPressed: widget.onSettings, child: const Text('全部存档 ›')),
                      ],
                    ),
                  ),
                  if (widget.worlds.isEmpty)
                    widget.loading ? SizedBox(height: worldsH) : const _EmptyWorlds()
                  else
                    Wrap(
                      spacing: _tileGap,
                      runSpacing: _tileGap,
                      children: [
                        for (final w in shown)
                          SizedBox(
                            width: tileW,
                            height: _tileH,
                            child: _WorldTile(
                              world: w,
                              versionName: widget.versionName(w.versionId),
                              onTap: w.versionId == null ? null : () => widget.state.selectVersion(w.versionId!),
                              onPlay: () => widget.onPlayWorld(w),
                            ),
                          ),
                      ],
                    ),
                  const SizedBox(height: _gap),
                  SizedBox(
                    height: _moreH,
                    child: Center(
                      child: TextButton.icon(
                        onPressed: () => _scroll.animateTo(
                          math.min(foldH, _scroll.position.maxScrollExtent),
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeOutCubic,
                        ),
                        style: TextButton.styleFrom(foregroundColor: theme.colorScheme.onSurfaceVariant),
                        iconAlignment: IconAlignment.end,
                        icon: const Icon(Icons.expand_more, size: 18),
                        label: const Text('向下滚动查看更多'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 20),
              child: AlignedSplit(
                gap: 12,
                crossAxisAlignment: CrossAxisAlignment.start,
                left: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [const ChangelogHint(), if (cfg.homeNews) const VersionNewsFeed()],
                ),
                right: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    if (widget.version != null)
                      _VersionInfoCard(
                        state: widget.state,
                        version: widget.version!,
                        latest: widget.latest,
                        onSettings: widget.onSettings,
                      ),
                    if (cfg.homeHints) ...[const SizedBox(height: 12), const HomeHints(compact: true)],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 桌面主卡片：中性底色（避免大面积鲜艳色块），版本图标收小放在标题旁边
class _DesktopHero extends StatelessWidget {
  const _DesktopHero({
    required this.state,
    required this.version,
    required this.latest,
    required this.onLaunch,
    required this.onVersions,
    required this.onSettings,
    required this.onLog,
    required this.onFolder,
  });

  final AppState state;
  final InstanceInfo? version;
  final RecentWorld? latest;
  final VoidCallback onLaunch;
  final VoidCallback onVersions;
  final VoidCallback? onSettings;
  final VoidCallback onLog;
  final VoidCallback? onFolder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final v = version;
    final versionDir = v == null ? null : state.paths.versionDir(v.id);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .4)),
        color: scheme.surfaceContainerLow,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: onVersions,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('切换版本', style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                    Icon(Icons.expand_more, size: 16, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (v != null) ...[
                VersionIcon(info: v, versionDir: versionDir!, size: 44, radius: 12),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      v == null ? '还没有选择版本' : versionTitle(v),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    if (v != null && versionTitle(v) != v.id)
                      Text(
                        v.id,
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
            ],
          ),
          const SizedBox(height: 8),
          if (v == null)
            Text('先下载或选择一个版本，准备好就开始', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant))
          else
            _VersionFacts(state: state, version: v, latest: latest, color: scheme.onSurfaceVariant),
          const SizedBox(height: 14),
          Row(
            children: [
              _LaunchButton(state: state, version: v, onLaunch: onLaunch),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onSettings,
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('版本设置'),
              ),
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) {
                  if (value == 'versions') onVersions();
                  if (value == 'log') onLog();
                  if (value == 'folder') onFolder?.call();
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'versions', child: Text('版本选择')),
                  PopupMenuItem(value: 'folder', enabled: onFolder != null, child: const Text('打开版本文件夹')),
                  const PopupMenuItem(value: 'log', child: Text('游戏日志')),
                ],
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.outline),
                  ),
                  child: Icon(Icons.more_horiz, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 桌面最近游玩：紧凑横条。小封面按接近原尺寸清晰显示（不放大发糊），
/// 底色从封面取一点主色，往右融进卡片底色；右边是启动按钮
class _WorldTile extends StatefulWidget {
  const _WorldTile({required this.world, required this.versionName, required this.onTap, required this.onPlay});

  final RecentWorld world;
  final String versionName;
  final VoidCallback? onTap;
  final VoidCallback onPlay;

  @override
  State<_WorldTile> createState() => _WorldTileState();
}

class _WorldTileState extends State<_WorldTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = p.join(widget.world.path, 'icon.png');
    final base = _hover ? scheme.surfaceContainer : scheme.surfaceContainerLow;
    return FutureBuilder<CoverPalette?>(
      future: CoverPalette.of(icon),
      builder: (context, snap) {
        final tint = snap.data?.colors.firstOrNull ?? scheme.primary;
        return MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Material(
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: Ink(
              decoration: BoxDecoration(color: Color.lerp(base, tint, _hover ? .22 : .12)),
              child: InkWell(
                onTap: widget.onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      CoverThumb(iconPath: icon, size: 44, radius: 9, modified: widget.world.modified),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.world.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              [
                                if (widget.versionName.isNotEmpty) widget.versionName,
                                _timeAgo(widget.world.modified),
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '进入这个存档的版本',
                        onPressed: widget.onPlay,
                        style: IconButton.styleFrom(
                          backgroundColor: _hover ? scheme.primaryFixed : scheme.onSurface.withValues(alpha: .06),
                          foregroundColor: _hover ? scheme.onPrimaryFixed : scheme.primary,
                          minimumSize: const Size(36, 36),
                          fixedSize: const Size(36, 36),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 往下滚部分的「当前版本」：版本、模组数、最近游玩的存档
class _VersionInfoCard extends StatelessWidget {
  const _VersionInfoCard({required this.state, required this.version, required this.latest, required this.onSettings});

  final AppState state;
  final InstanceInfo version;
  final RecentWorld? latest;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget row(String k, String v, {bool first = false}) => Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: .4))),
      ),
      child: Row(
        children: [
          Text(k, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              v,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('当前版本', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton(onPressed: onSettings, child: const Text('版本设置 ›')),
            ],
          ),
          row('版本', describeVersion(version), first: true),
          FutureBuilder<int?>(
            future: version.loader == Loader.vanilla ? Future.value(null) : _modCount(state, version),
            builder: (context, snap) =>
                row('模组', version.loader == Loader.vanilla ? '原版，不加载模组' : (snap.data == null ? '—' : '${snap.data} 个')),
          ),
          row('最近游玩', latest == null ? '还没玩过' : '${latest!.name} · ${_timeAgo(latest!.modified)}'),
          row('版本 ID', version.id),
        ],
      ),
    );
  }
}
