import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:window_manager/window_manager.dart';

import 'app_scope.dart';
import 'core/accounts.dart';
import 'core/instance_files.dart';
import 'app_state.dart';
import 'core/crash.dart';
import 'platform.dart';
import 'widgets/accounts_dialog.dart';
import 'widgets/app_logo.dart';
import 'widgets/device_status.dart';
import 'widgets/shell_layout.dart';
import 'widgets/storage_location.dart';
import 'widgets/update_dialog.dart';
import 'widgets/window_buttons.dart';
import 'pages/ai_page.dart';
import 'pages/diagnose_page.dart';
import 'pages/download_page.dart';
import 'pages/home_feed.dart';
import 'pages/home_page.dart';
import 'pages/instance_page.dart';
import 'pages/log_page.dart';
import 'pages/settings_page.dart';
import 'pages/tasks_page.dart';
import 'pages/tools_page.dart';
import 'pages/versions_page.dart';

export 'widgets/shell_layout.dart' show AlignedSplit;

enum MainPage { home, download, settings, tools, ai }

/// 从主页面进入的子页面：顶栏显示返回按钮和标题
enum SubPage { versions, log, instance, tasks, diagnose }

const _subTitles = {
  SubPage.versions: '版本选择',
  SubPage.log: '游戏日志',
  SubPage.instance: '版本详情',
  SubPage.tasks: '任务历史',
  SubPage.diagnose: '错误分析',
};

const _mainTitles = {
  MainPage.home: '启动',
  MainPage.download: '下载',
  MainPage.settings: '设置',
  MainPage.tools: '工具',
  MainPage.ai: 'AI 助手',
};

/// 页面切换，供各页面打开子页面或返回
class ShellNav extends InheritedWidget {
  const ShellNav({super.key, required this.open, required this.back, required this.goMain, required super.child});

  final void Function(SubPage) open;
  final VoidCallback back;

  /// 关闭子页面并切换到某个主页面
  final void Function(MainPage) goMain;

  static ShellNav of(BuildContext context) => context.getInheritedWidgetOfExactType<ShellNav>()!;

  @override
  bool updateShouldNotify(ShellNav old) => false;
}

/// 主窗口：左边是窄侧栏，右边是顶栏和页面内容。
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  MainPage _page = MainPage.home;
  SubPage? _sub;
  StreamSubscription<CrashReport>? _crashes;
  final _navKey = GlobalKey();
  final _rootKey = GlobalKey();
  final _splitX = ValueNotifier<double?>(null);
  bool _askedStorage = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 游戏崩溃时弹出提示
    _crashes ??= AppScope.read(context).crashes.listen((report) {
      final ctx = _navKey.currentContext;
      if (ctx != null && ctx.mounted) showCrashDialog(ctx, report);
    });
    if (!_askedStorage) {
      _askedStorage = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _navKey.currentContext;
        if (ctx != null && ctx.mounted) askStorageOnFirstRun(ctx);
      });
      // 启动后稍等一会再检查更新，不和首次运行的提示抢
      Future<void>.delayed(const Duration(seconds: 5), () {
        final ctx = _navKey.currentContext;
        if (ctx != null && ctx.mounted && AppScope.read(ctx).config.updateAutoCheck) checkUpdates(ctx, manual: false);
      });
    }
  }

  @override
  void dispose() {
    _crashes?.cancel();
    _splitX.dispose();
    super.dispose();
  }

  void _goMain(MainPage page) => setState(() {
    _sub = null;
    _page = page;
  });

  void _openSub(SubPage page) => setState(() => _sub = page);

  @override
  Widget build(BuildContext context) {
    final pageView = switch (_sub) {
      SubPage.versions => const VersionsPage(),
      SubPage.log => const LogPage(),
      SubPage.instance => const InstancePage(),
      SubPage.tasks => const TasksPage(),
      SubPage.diagnose => const DiagnosePage(),
      null => IndexedStack(
        index: _page.index,
        children: const [HomePage(), DownloadPage(), SettingsPage(), ToolsPage(), AiPage()],
      ),
    };
    final scheme = Theme.of(context).colorScheme;

    final shell = Scaffold(
      key: _navKey,
      backgroundColor: scheme.surface,
      body: KeyedSubtree(
        key: _rootKey,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Rail(page: _page, sub: _sub, onMain: _goMain),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeLeft: true,
                removeTop: true,
                removeRight: true,
                removeBottom: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TopBar(
                      page: _page,
                      sub: _sub,
                      onBack: () => setState(() => _sub = null),
                      rootKey: _rootKey,
                      splitX: _splitX,
                    ),
                    Expanded(child: pageView),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return ShellLayout(
      rootKey: _rootKey,
      splitX: _splitX,
      child: ShellNav(open: _openSub, back: () => setState(() => _sub = null), goMain: _goMain, child: shell),
    );
  }
}

/// 窄侧栏：图标 + 短文字。手机横屏时背景一直铺到挖孔那一侧，内容从挖孔右边开始。
class _Rail extends StatelessWidget {
  const _Rail({required this.page, required this.sub, required this.onMain});

  final MainPage page;
  final SubPage? sub;
  final ValueChanged<MainPage> onMain;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inset = MediaQuery.paddingOf(context).left;
    // macOS 的红绿灯在左上角，图标从它们下面开始
    final top = Platform.isMacOS ? 40.0 : 10.0;
    Widget item(MainPage p, IconData icon, IconData active, String label) => _RailItem(
      icon: icon,
      activeIcon: active,
      label: label,
      selected: page == p && (sub == null || p == MainPage.home && sub == SubPage.instance),
      onTap: () => onMain(p),
    );
    return Container(
      width: 76 + inset,
      padding: EdgeInsets.fromLTRB(inset, top, 0, 10),
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          const AppLogo(size: 30),
          const SizedBox(height: 10),
          item(MainPage.home, Icons.rocket_launch_outlined, Icons.rocket_launch, '启动'),
          item(MainPage.download, Icons.download_outlined, Icons.download, '下载'),
          item(MainPage.tools, Icons.construction_outlined, Icons.construction, '工具'),
          // 手机上的内置文件管理器（电脑上打开文件夹用系统的资源管理器）
          if (!isDesktop)
            _RailItem(
              icon: Icons.folder_outlined,
              activeIcon: Icons.folder,
              label: '文件',
              selected: false,
              onTap: () => openInFileManager(AppScope.read(context).config.gameDir),
            ),
          item(MainPage.settings, Icons.settings_outlined, Icons.settings, '设置'),
          item(MainPage.ai, Icons.chat_bubble_outline, Icons.chat_bubble, 'AI'),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 64,
          height: 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 52,
                height: 30,
                decoration: BoxDecoration(
                  color: selected ? scheme.primaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(
                  selected ? activeIcon : icon,
                  size: 21,
                  color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 内容区顶栏：标题（首页是问候语）、后台任务、搜索与通知、设备状态、账户、窗口按钮。
class _TopBar extends StatefulWidget {
  const _TopBar({
    required this.page,
    required this.sub,
    required this.onBack,
    required this.rootKey,
    required this.splitX,
  });

  final MainPage page;
  final SubPage? sub;
  final VoidCallback onBack;
  final GlobalKey rootKey;
  final ValueNotifier<double?> splitX;

  @override
  State<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<_TopBar> {
  final _tasksKey = GlobalKey();

  /// 量出「后台任务」右边缘，供页面对齐左右两栏
  void _measure() {
    final root = widget.rootKey.currentContext?.findRenderObject();
    final box = _tasksKey.currentContext?.findRenderObject();
    if (root is! RenderBox || box is! RenderBox || !box.attached || !root.attached) return;
    final x = box.localToGlobal(Offset(box.size.width, 0), ancestor: root).dx;
    if (widget.splitX.value == null || (widget.splitX.value! - x).abs() > .5) widget.splitX.value = x;
  }

  @override
  Widget build(BuildContext context) {
    SchedulerBinding.instance.addPostFrameCallback((_) => _measure());
    return LayoutBuilder(
      builder: (context, c) {
        // 按可用宽度分三档：宽 ≥ 900 全部显示；中等去掉问候语后的小字、账户只显示头像；窄再收起「公告」
        final compact = c.maxWidth < 900;
        final tight = c.maxWidth < 760;
        return _bar(context, compact: compact, tight: tight);
      },
    );
  }

  Widget _bar(BuildContext context, {required bool compact, required bool tight}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = AppScope.of(context);
    final sub = widget.sub;
    Widget title;
    if (sub != null) {
      final text = sub == SubPage.instance ? '版本详情' : _subTitles[sub]!;
      title = Row(
        children: [
          IconButton(tooltip: '返回', onPressed: widget.onBack, icon: const Icon(Icons.arrow_back, size: 20)),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      );
    } else if (widget.page == MainPage.home) {
      title = Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: greeting(state.selectedAccount?.name),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (!compact)
              TextSpan(
                text: '  准备好冒险了吗？',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium,
      );
    } else {
      title = Text(
        _mainTitles[widget.page]!,
        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      );
    }
    // 桌面端：标题区域拖动窗口
    Widget titleArea = Align(alignment: Alignment.centerLeft, child: title);
    if (isDesktop && !Platform.isLinux) titleArea = DragToMoveArea(child: SizedBox.expand(child: titleArea));

    return SizedBox(
      height: 56,
      child: Padding(
        padding: EdgeInsets.only(left: sub != null ? 6 : 14, right: isDesktop && !nativeWindowButtons ? 0 : 14),
        child: Row(
          children: [
            Expanded(child: titleArea),
            const SizedBox(width: 8),
            _TasksPill(key: _tasksKey, width: tight ? 168 : (compact ? 200 : 236)),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '版本选择',
              onPressed: () => ShellNav.of(context).open(SubPage.versions),
              icon: const Icon(Icons.search, size: 21),
            ),
            if (!tight)
              IconButton(
                tooltip: '公告',
                onPressed: () => showNoticesDialog(context),
                icon: const Icon(Icons.notifications_none_outlined, size: 21),
              ),
            if (!isDesktop) ...[const SizedBox(width: 4), const _BarChip(child: DeviceStatus())],
            const SizedBox(width: 6),
            _AccountChip(avatarOnly: compact),
            if (isDesktop && !nativeWindowButtons) ...[const SizedBox(width: 8), const WindowButtons()],
          ],
        ),
      ),
    );
  }
}

/// 首页问候语
String greeting(String? name) {
  final h = DateTime.now().hour;
  final when = h < 5
      ? '夜深了'
      : h < 11
      ? '早上好'
      : h < 13
      ? '中午好'
      : h < 18
      ? '下午好'
      : '晚上好';
  return name == null ? when : '$when，$name';
}

/// 顶栏里统一样式的小块按钮
class _BarChip extends StatelessWidget {
  const _BarChip({required this.child, this.onTap, this.color, this.padding});

  final Widget child;
  final VoidCallback? onTap;
  final Color? color;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: color ?? scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(9),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 38,
          padding: padding ?? const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}

/// 后台任务：没有任务时显示「当前无后台任务」；有任务时显示第一个任务和进度。点击进入任务页。
class _TasksPill extends StatelessWidget {
  const _TasksPill({super.key, required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = AppScope.of(context);
    final running = state.runningTasks;
    final task = running.firstOrNull;
    // 没有后台任务但游戏在运行时显示运行中的实例数（点击仍进入任务页）
    final games = state.gameState == GameState.running ? 1 : 0;
    return SizedBox(
      width: width,
      child: _BarChip(
        onTap: () => ShellNav.of(context).open(SubPage.tasks),
        color: task == null ? null : scheme.primaryContainer,
        child: task == null
            ? Row(
                children: [
                  Icon(games > 0 ? Icons.sports_esports_outlined : Icons.check, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      games > 0 ? '$games 个游戏实例运行中' : '当前无后台任务',
                      style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
                ],
              )
            : ListenableBuilder(
                listenable: task,
                builder: (context, _) => Row(
                  children: [
                    Icon(Icons.downloading, size: 16, color: scheme.onPrimaryContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            running.length > 1 ? '${task.title} · 共 ${running.length} 个任务' : task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(color: scheme.onPrimaryContainer),
                          ),
                          const SizedBox(height: 3),
                          LinearProgressIndicator(
                            value: task.fraction,
                            minHeight: 3,
                            borderRadius: BorderRadius.circular(2),
                            color: scheme.primary,
                            backgroundColor: scheme.onPrimaryContainer.withValues(alpha: .15),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, size: 16, color: scheme.onPrimaryContainer),
                  ],
                ),
              ),
      ),
    );
  }
}

/// 账户：头像首字母 + 名称 · 类型，点击切换账户
class _AccountChip extends StatelessWidget {
  const _AccountChip({this.avatarOnly = false});

  /// 窄屏只显示头像，名称放在提示里
  final bool avatarOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final account = AppScope.of(context).selectedAccount;
    final kind = switch (account?.type) {
      null => '',
      AccountType.microsoft => ' · 正版',
      AccountType.offline => ' · 离线',
      _ => ' · ${account!.serverName ?? '外置'}',
    };
    final chip = _BarChip(
      onTap: () => showAccountsDialog(context),
      padding: EdgeInsets.only(left: 7, right: avatarOnly ? 7 : 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(6)),
            child: Text(
              account == null ? '+' : account.name.characters.first.toUpperCase(),
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (!avatarOnly) const SizedBox(width: 7),
          if (!avatarOnly)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                account == null ? '添加账户' : '${account.name}$kind',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium,
              ),
            ),
        ],
      ),
    );
    return Tooltip(message: account == null ? '添加账户' : '${account.name}$kind', child: chip);
  }
}
