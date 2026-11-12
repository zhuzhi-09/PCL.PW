import 'package:flutter/material.dart';

import '../core/instance.dart';
import 'loader_icon.dart';

class SideNavItem<T> {
  const SideNavItem(this.value, this.label, this.icon, {this.trailing, this.loader});

  final T value;
  final String label;
  final IconData icon;
  final String? trailing;

  /// 设置时显示加载器图标，代替 [icon]
  final Loader? loader;
}

class SideNavGroup<T> {
  const SideNavGroup(this.title, this.items);

  final String? title;
  final List<SideNavItem<T>> items;
}

/// 二级页面左侧的分组导航（MD3 导航抽屉）：每项 44 高，选中项是药丸形的 secondaryContainer 指示器
class SideNav<T> extends StatelessWidget {
  const SideNav({super.key, required this.groups, required this.value, required this.onChanged, this.width = 196});

  final List<SideNavGroup<T>> groups;
  final T value;
  final ValueChanged<T> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: width,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 0, 6, 16),
        children: [
          for (final g in groups) ...[
            if (g.title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                child: Text(g.title!, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            for (final item in g.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: _SideNavTile(item: item, selected: item.value == value, onTap: () => onChanged(item.value)),
              ),
          ],
        ],
      ),
    );
  }
}

class _SideNavTile<T> extends StatelessWidget {
  const _SideNavTile({required this.item, required this.selected, required this.onTap});

  final SideNavItem<T> item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    final iconColor = fg;
    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      animationDuration: const Duration(milliseconds: 150),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              const SizedBox(width: 16),
              if (item.loader != null)
                LoaderIcon(item.loader!, size: 19, color: iconColor)
              else
                Icon(item.icon, size: 19, color: iconColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: fg,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (item.trailing != null) Text(item.trailing!, style: theme.textTheme.labelSmall?.copyWith(color: fg)),
              const SizedBox(width: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// 右侧内容区（新外壳里不再画单独的底板，只负责裁剪）
class ContentPanel extends StatelessWidget {
  const ContentPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(child: child);
}

/// 页面顶部的一排分类标签（下载、版本详情等），每个标签 40 高，选中项下面有主题色下划线
class PageTabs<T> extends StatelessWidget {
  const PageTabs({super.key, required this.tabs, required this.value, required this.onChanged, this.trailing});

  final List<(T, String)> tabs;
  final T value;
  final ValueChanged<T> onChanged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      height: 44,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: .4))),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final (v, label) in tabs)
                  InkWell(
                    onTap: () => onChanged(v),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: v == value ? scheme.primary : Colors.transparent, width: 2),
                        ),
                      ),
                      child: Text(
                        label,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: v == value ? scheme.onSurface : scheme.onSurfaceVariant,
                          fontWeight: v == value ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 一组互斥的小选项（正式版 / 快照 / …），每项 34 高
class SegmentPicker<T> extends StatelessWidget {
  const SegmentPicker({super.key, required this.options, required this.value, required this.onChanged});

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (v, label) in options)
            Material(
              color: v == value ? scheme.secondaryContainer : Colors.transparent,
              shape: const StadiumBorder(),
              child: InkWell(
                onTap: () => onChanged(v),
                customBorder: const StadiumBorder(),
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  child: Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: v == value ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
                      fontWeight: v == value ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 尚未从 Electron 版迁移过来的功能
class MigratingPlaceholder extends StatelessWidget {
  const MigratingPlaceholder({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.construction, size: 48, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('这部分功能正在迁移中', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
