import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_info.dart';
import '../app_scope.dart';
import '../platform.dart';
import '../widgets/theme_color_dialog.dart';
import '../widgets/settings_group.dart';
import '../widgets/side_nav.dart';
import '../widgets/ai_settings.dart';
import '../widgets/ai_workspace_settings.dart';
import '../widgets/storage_location.dart';
import 'settings_sections.dart';

enum _Section { launch, java, manage, appearance, misc, ai, aiTools, aiWorkspace, about }

/// 从别的页面跳到设置的某个小节（值为小节名，例如 ai、aiTools、aiWorkspace），见 ShellNav.openSettings
final settingsSectionRequest = ValueNotifier<String?>(null);

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  _Section _section = _Section.launch;

  @override
  void initState() {
    super.initState();
    settingsSectionRequest.addListener(_onRequest);
    _onRequest();
  }

  @override
  void dispose() {
    settingsSectionRequest.removeListener(_onRequest);
    super.dispose();
  }

  void _onRequest() {
    final s = _Section.values.asNameMap()[settingsSectionRequest.value];
    if (s == null) return;
    settingsSectionRequest.value = null;
    if (mounted) setState(() => _section = s);
  }

  /// AI 的几个小节共用的外框
  static Widget _aiPage(String title, String? intro, Widget child) => ListView(
    padding: const EdgeInsets.fromLTRB(6, 2, 16, 16),
    children: [
      SettingsGroup(
        title: title,
        children: [
          if (intro != null) Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 0), child: Text(intro)),
          Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 20), child: child),
        ],
      ),
    ],
  );

  static const _groups = [
    SideNavGroup('游戏', [
      SideNavItem(_Section.launch, '启动', Icons.rocket_launch_outlined),
      SideNavItem(_Section.java, 'Java', Icons.coffee_outlined),
      SideNavItem(_Section.manage, '游戏管理', Icons.folder_outlined),
    ]),
    SideNavGroup('启动器', [
      SideNavItem(_Section.appearance, '个性化', Icons.palette_outlined),
      SideNavItem(_Section.misc, '其他', Icons.tune),
    ]),
    SideNavGroup('AI', [
      SideNavItem(_Section.ai, '模型与接口', Icons.auto_awesome_outlined),
      SideNavItem(_Section.aiTools, '工具与服务', Icons.extension_outlined),
      SideNavItem(_Section.aiWorkspace, '工作区与联网', Icons.travel_explore),
    ]),
    SideNavGroup('关于', [SideNavItem(_Section.about, '关于与致谢', Icons.info_outline)]),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SideNav(groups: _groups, value: _section, onChanged: (s) => setState(() => _section = s)),
        Expanded(
          child: ContentPanel(
            child: switch (_section) {
              _Section.launch => const LaunchSection(),
              _Section.java => const JavaSection(),
              _Section.misc => const MiscSection(),
              _Section.manage => const GameStorageSection(),
              _Section.appearance => const _AppearanceSection(),
              _Section.ai => _aiPage(
                '模型与接口',
                'AI 助手使用你自己的 AI 服务。支持 OpenAI 兼容接口（DeepSeek、通义千问、Kimi、OpenRouter、本机 Ollama 等）'
                    '和 Anthropic 接口；费用由你的 AI 服务商收取。',
                const AiSettingsForm(),
              ),
              _Section.aiTools => _aiPage('工具与服务', null, const AiToolsSettings()),
              _Section.aiWorkspace => _aiPage('工作区与联网', null, const AiWorkspaceSettings()),
              _Section.about => const _AboutSection(),
            },
          ),
        ),
      ],
    );
  }
}

/// 没有缩放时的屏幕尺寸（去掉系统栏），用来显示「自动」算出的比例
Size _unscaledSize(BuildContext context) {
  final view = View.of(context);
  final padding = view.padding;
  final w = view.physicalSize.width - padding.right;
  final h = view.physicalSize.height - padding.top - padding.bottom;
  return Size(w, h) / view.devicePixelRatio;
}

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) {
    final cfg = AppScope.of(context).config;
    return ListView(
      padding: const EdgeInsets.fromLTRB(6, 2, 16, 16),
      children: [
        SettingsGroup(
          title: '个性化',
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              leading: const Icon(Icons.dark_mode_outlined),
              title: const Text('颜色模式'),
              subtitle: const Text('启动器界面的明暗模式'),
              trailing: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'system', label: Text('跟随系统'), icon: Icon(Icons.brightness_auto)),
                  ButtonSegment(value: 'light', label: Text('浅色'), icon: Icon(Icons.light_mode_outlined)),
                  ButtonSegment(value: 'dark', label: Text('深色'), icon: Icon(Icons.dark_mode_outlined)),
                ],
                selected: {cfg.themeMode},
                onSelectionChanged: (s) => cfg.update({'themeMode': s.first}),
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              leading: const Icon(Icons.zoom_out_map),
              title: const Text('界面缩放'),
              subtitle: Text(
                cfg.uiScale > 0
                    ? '整个启动器按这个比例显示'
                    : '自动：按屏幕尺寸计算，当前为 ${(autoUiScale(_unscaledSize(context)) * 100).round()}%',
              ),
              trailing: DropdownButton<double>(
                value: uiScaleOptions.contains(cfg.uiScale) ? cfg.uiScale : 0.0,
                underline: const SizedBox.shrink(),
                borderRadius: BorderRadius.circular(12),
                items: [
                  for (final v in uiScaleOptions)
                    DropdownMenuItem(value: v, child: Text(v == 0 ? '自动' : '${(v * 100).round()}%')),
                ],
                onChanged: (v) => cfg.update({'uiScale': v ?? 0.0}),
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              leading: CircleAvatar(radius: 13, backgroundColor: Color(cfg.themeColor)),
              title: const Text('主题色'),
              subtitle: const Text('按 Material Design 3 从主题色生成整套浅色与深色配色'),
              trailing: const Icon(Icons.palette_outlined),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: ThemeColorPicker(current: cfg.themeColor, onChanged: (color) => cfg.update({'themeColor': color})),
            ),
          ],
        ),
        SettingsGroup(
          title: '首页',
          children: [
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              secondary: const Icon(Icons.info_outline),
              title: const Text('显示使用提示'),
              subtitle: const Text('正在使用的版本与免费声明'),
              value: AppScope.of(context).config.homeHints,
              onChanged: (v) => AppScope.read(context).config.update({'homeHints': v}),
            ),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              secondary: const Icon(Icons.newspaper_outlined),
              title: const Text('显示 Minecraft 版本动态'),
              subtitle: const Text('最新的正式版与快照，简介来自中文 Minecraft Wiki'),
              value: AppScope.of(context).config.homeNews,
              onChanged: (v) => AppScope.read(context).config.update({'homeNews': v}),
            ),
          ],
        ),
      ],
    );
  }
}

/// 关于页。按《PCL 存储库合理使用指南》第 3 条，首位为龙腾猫跃的署名及赞助链接。
class _AboutSection extends StatelessWidget {
  const _AboutSection();

  static void _open(String url) => launchUrl(Uri.parse(url));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    ListTile link(IconData icon, String title, String subtitle, String url, {String action = '查看'}) => ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: TextButton(onPressed: () => _open(url), child: Text(action)),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(6, 2, 16, 16),
      children: [
        SettingsGroup(
          title: '关于',
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              leading: CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
                child: const Icon(Icons.favorite),
              ),
              title: const Text(AppInfo.authorName),
              subtitle: const Text('Pixel World 的开发者'),
              trailing: FilledButton.icon(
                onPressed: () => _open(AppInfo.sponsorUrl),
                icon: const Icon(Icons.volunteer_activism_outlined),
                label: const Text('赞助作者'),
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              // 图标的立方体是白色，用带蓝底的版本，浅色背景上也看得清
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset('assets/icon/icon.png', width: 40, height: 40),
              ),
              title: Text('${AppInfo.fullName} ${AppInfo.version}'),
              subtitle: const Text(
                'Pixel World 是第三方 Minecraft 启动器，本项目为轻度使用 PCL 仓储库，界面布局参考 PCL 社区版（PCL-CE）。'
                'PCL 由龙腾猫跃开发，本软件与 PCL 及其作者无关，也不代表 PCL 官方。'
                '请勿就本软件的问题打扰 PCL 作者。',
              ),
            ),
            link(Icons.code, '源代码', 'Pixel World 以 Apache-2.0 协议开源', AppInfo.repoUrl, action: '打开'),
            link(
              Icons.gavel_outlined,
              'PCL 存储库合理使用指南',
              '本项目遵循的命名、署名与使用规则，随源代码一同发布',
              '${AppInfo.repoUrl}/blob/main/PCL-GUIDE.md',
            ),
          ],
        ),
        SettingsGroup(
          title: '致谢',
          children: [
            link(
              Icons.groups_outlined,
              'PCL Community',
              'PCL 社区版（PCL-CE）的开发者们，本软件与 PCL-CE 的数据兼容',
              AppInfo.pclCeRepoUrl,
            ),
            link(
              Icons.android,
              '安卓版游戏运行时',
              '基于 Amethyst-Android（LGPL-3.0）、MobileGlues、Krypton Wrapper、LWJGL 与 OpenJDK，单独以 LGPL-3.0 开源',
              '${AppInfo.repoUrl}/blob/main/android/runtime/NOTICE.md',
            ),
            link(Icons.flutter_dash, 'Flutter', '跨平台界面框架', 'https://flutter.dev'),
            link(Icons.palette_outlined, 'Material Design 3', '界面设计语言与配色算法', 'https://m3.material.io'),
          ],
        ),
        Text(
          'Minecraft 是 Mojang Studios 的商标。本软件不是官方 Minecraft 产品，未经 Mojang 或 Microsoft 批准，也与其无关。',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
