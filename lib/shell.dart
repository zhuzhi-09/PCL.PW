import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_info.dart';
import 'app_scope.dart';
import 'core/crash.dart';
import 'platform.dart';
import 'widgets/accounts_dialog.dart';
import 'widgets/app_logo.dart';
import 'widgets/device_status.dart';
import 'widgets/storage_location.dart';
import 'widgets/task_steps.dart';
import 'widgets/update_dialog.dart';
import 'widgets/window_buttons.dart';
import 'pages/ai_page.dart';
import 'pages/diagnose_page.dart';
import 'pages/download_page.dart';
import 'pages/home_page.dart';
import 'pages/instance_page.dart';
import 'pages/log_page.dart';
import 'pages/settings_page.dart';
import 'pages/tasks_page.dart';
import 'pages/tools_page.dart';
import 'pages/versions_page.dart';

enum MainPage { home, download, settings, tools, ai }

/// 从主页面进入的子页面：顶部显示返回按钮和标题
enum SubPage { versions, log, instance, tasks, diagnose }

const _subTitles = {
  SubPage.versions: '版本选择',
  SubPage.log: '游戏日志',
  SubPage.instance: '版本设置',
  SubPage.tasks: '任务历史',
  SubPage.diagnose: '错误分析',
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

/// 主窗口：左侧是品牌与页面导航，右侧是内容区。
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
  bool _sidebarCollapsed = false;

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

  bool _askedStorage = false;

  @override
  void dispose() {
    _crashes?.cancel();
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
    final subTitle = _sub == SubPage.instance ? '版本设置 - ${AppScope.of(context).instanceId}' : _subTitles[_sub];

    final sidebarWidth = isDesktop ? 236.0 : 210.0;
    return ShellNav(
      open: _openSub,
      back: () => setState(() => _sub = null),
      goMain: _goMain,
      child: Scaffold(
        body: Stack(
          key: _navKey,
          children: [
            Positioned.fill(child: ColoredBox(color: Theme.of(context).colorScheme.surface)),
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: sidebarWidth, end: _sidebarCollapsed ? 64 : sidebarWidth),
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: _Sidebar(
                    page: _page,
                    sub: _sub,
                    collapsed: _sidebarCollapsed,
                    onMain: _goMain,
                    onSub: _openSub,
                  ),
                  builder: (context, width, child) => SizedBox(
                    width: width,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: _sidebarCollapsed ? 64 : sidebarWidth,
                        maxWidth: _sidebarCollapsed ? 64 : sidebarWidth,
                        child: SizedBox(
                          width: _sidebarCollapsed ? 64 : sidebarWidth,
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      _TopBar(
                        subTitle: subTitle,
                        collapsed: _sidebarCollapsed,
                        onToggleSidebar: () => setState(() => _sidebarCollapsed = !_sidebarCollapsed),
                        onBack: () => setState(() => _sub = null),
                      ),
                      Expanded(child: pageView),
                    ],
                  ),
                ),
              ],
            ),
            const Positioned(right: 20, bottom: 20, child: _InstallProgress()),
          ],
        ),
      ),
    );
  }
}

/// 左侧品牌、账户和主导航
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.page,
    required this.sub,
    required this.collapsed,
    required this.onMain,
    required this.onSub,
  });

  final MainPage page;
  final SubPage? sub;
  final bool collapsed;
  final ValueChanged<MainPage> onMain;
  final ValueChanged<SubPage> onSub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = AppScope.of(context);
    final account = state.selectedAccount;
    final width = collapsed ? 64.0 : (isDesktop ? 236.0 : 210.0);
    final topInset = isDesktop && nativeWindowButtons ? macTrafficLightsWidth : 0.0;

    Widget brand = Padding(
      padding: collapsed
          ? const EdgeInsets.symmetric(vertical: 20)
          : EdgeInsets.fromLTRB(18 + topInset, 20, 16, 16),
      child: collapsed
          ? const Center(child: AppLogo(size: 36))
          : Row(
              children: [
                const AppLogo(size: 38),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    AppInfo.brandName,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: .2),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
    );
    if (isDesktop) brand = DragToMoveArea(child: brand);

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(right: BorderSide(color: scheme.outlineVariant.withValues(alpha: .45))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          brand,
          if (collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              child: Tooltip(
                message: account?.name ?? '添加账户',
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => showAccountsDialog(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Center(
                      child: CircleAvatar(
                        radius: 17,
                        backgroundColor: scheme.primaryContainer,
                        foregroundColor: scheme.onPrimaryContainer,
                        child: Text(
                          account == null ? '+' : account.name.characters.first.toUpperCase(),
                          style: theme.textTheme.labelLarge,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Material(
                color: scheme.surfaceContainerHighest.withValues(alpha: .45),
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => showAccountsDialog(context),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 17,
                          backgroundColor: scheme.primaryContainer,
                          foregroundColor: scheme.onPrimaryContainer,
                          child: Text(
                            account == null ? '+' : account.name.characters.first.toUpperCase(),
                            style: theme.textTheme.labelLarge,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                account?.name ?? '添加账户',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelLarge,
                              ),
                              Text(
                                account == null ? '账户' : (account.type.name == 'microsoft' ? '微软账户' : '离线账户'),
                                maxLines: 1,
                                style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.unfold_more, size: 16, color: scheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.symmetric(horizontal: collapsed ? 8 : 12),
              children: [
                _SideItem(
                  icon: Icons.rocket_launch_outlined,
                  activeIcon: Icons.rocket_launch,
                  label: '启动',
                    collapsed: collapsed,
                  selected: sub == null && page == MainPage.home,
                  onTap: () => onMain(MainPage.home),
                ),
                _SideItem(
                  icon: Icons.download_outlined,
                  activeIcon: Icons.download,
                  label: '下载',
                    collapsed: collapsed,
                  selected: sub == null && page == MainPage.download,
                  onTap: () => onMain(MainPage.download),
                ),
                _SideItem(
                  icon: Icons.construction_outlined,
                  activeIcon: Icons.construction,
                  label: '工具',
                    collapsed: collapsed,
                  selected: sub == null && page == MainPage.tools,
                  onTap: () => onMain(MainPage.tools),
                ),
                _SideItem(
                  icon: Icons.settings_outlined,
                  activeIcon: Icons.settings,
                  label: '设置',
                    collapsed: collapsed,
                  selected: sub == null && page == MainPage.settings,
                  onTap: () => onMain(MainPage.settings),
                ),
                _SideItem(
                  icon: Icons.auto_awesome_outlined,
                  activeIcon: Icons.auto_awesome,
                  label: 'AI 助手',
                    collapsed: collapsed,
                  selected: sub == null && page == MainPage.ai,
                  onTap: () => onMain(MainPage.ai),
                ),
                _SideItem(
                  icon: Icons.history_outlined,
                  activeIcon: Icons.history,
                  label: '任务历史',
                    collapsed: collapsed,
                  selected: sub == SubPage.tasks,
                  onTap: () => onSub(SubPage.tasks),
                  badge: state.runningTasks.length,
                ),
              ],
            ),
          ),
          if (!collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
              child: Text(
                '${AppInfo.brandName} v${AppInfo.version}',
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: .7)),
              ),
            ),
        ],
      ),
    );
  }
}

class _SideItem extends StatelessWidget {
  const _SideItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.collapsed,
    this.badge = 0,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool collapsed;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Tooltip(
          message: label,
          child: Material(
            color: selected ? scheme.primaryContainer.withValues(alpha: .72) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(
                height: 44,
                child: Center(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(selected ? activeIcon : icon, size: 21, color: fg),
                      if (badge > 0)
                        Positioned(
                          right: -5,
                          top: -5,
                          child: Container(
                            width: 14,
                            height: 14,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                            child: Text(
                              '$badge',
                              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onPrimary, fontSize: 8),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: selected ? scheme.primaryContainer.withValues(alpha: .72) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                const SizedBox(width: 14),
                Icon(selected ? activeIcon : icon, size: 21, color: fg),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (badge > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(99)),
                      child: Text('$badge', style: theme.textTheme.labelSmall?.copyWith(color: scheme.onPrimary)),
                    ),
                  )
                else
                  const SizedBox(width: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 内容区顶部的拖动条、子页面返回按钮和窗口按钮
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.subTitle,
    required this.collapsed,
    required this.onToggleSidebar,
    required this.onBack,
  });

  final String? subTitle;
  final bool collapsed;
  final VoidCallback onToggleSidebar;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 56,
      child: Stack(
        children: [
          if (isDesktop) Positioned.fill(child: DragToMoveArea(child: const SizedBox.expand())),
          Positioned(
            left: 6,
            top: 0,
            bottom: 0,
            child: Center(
              child: SizedBox.square(
                dimension: 40,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  tooltip: collapsed ? '展开侧栏' : '收起侧栏',
                  onPressed: onToggleSidebar,
                  icon: Icon(collapsed ? Icons.menu : Icons.chevron_left, size: 20),
                ),
              ),
            ),
          ),
          if (subTitle != null)
            Positioned(
              left: 52,
              top: 0,
              bottom: 0,
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回',
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back, size: 20),
                  ),
                  const SizedBox(width: 2),
                  Text(subTitle!, style: theme.textTheme.titleSmall),
                ],
              ),
            ),
          if (!isDesktop) const Positioned(right: 8, top: 0, bottom: 0, child: Center(child: DeviceStatus())),
          if (isDesktop && !nativeWindowButtons) const Positioned(right: 0, top: 0, child: WindowButtons()),
        ],
      ),
    );
  }
}

/// 右下角的任务进度，点击进入任务页查看详情
class _InstallProgress extends StatelessWidget {
  const _InstallProgress();

  @override
  Widget build(BuildContext context) {
    final running = AppScope.of(context).runningTasks;
    if (running.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      elevation: 3,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => ShellNav.of(context).open(SubPage.tasks),
        child: Container(
          width: 340,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final t in running.take(3))
                ListenableBuilder(
                  listenable: t,
                  builder: (context, _) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(t.title, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                        if (t.steps.isNotEmpty) ...[const SizedBox(height: 4), TaskSteps(task: t, dense: true)],
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: Text(t.stage, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                            ),
                            if (t.total > 0) Text(t.countText, style: theme.textTheme.labelSmall),
                          ],
                        ),
                        const SizedBox(height: 6),
                        LinearProgressIndicator(value: t.fraction, borderRadius: BorderRadius.circular(4)),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                running.length > 3 ? '还有 ${running.length - 3} 个任务 · 点击查看详情' : '点击查看详情',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
