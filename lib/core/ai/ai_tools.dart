import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../app_state.dart';
import 'ai_client.dart';
import '../android_runtime.dart' show androidJavaAt, androidJavaHome, androidJavaMajors;
import '../android_storage.dart' show moveEntity;
import '../backup.dart';
import '../crash.dart';
import '../instance.dart';
import '../instance_config.dart';
import '../install.dart';
import '../java.dart' show javaTooNewWarning;
import '../instance_files.dart';
import '../loader_names.dart';
import '../loaders.dart';
import '../memory.dart';
import '../modrinth.dart';
import '../optifine_compat.dart';
import '../paths.dart';
import '../safe_path.dart';
import '../version.dart';
import 'web_tools.dart';
import 'workspace_tools.dart';

/// 操作的类型：只读操作默认直接执行；其余都要用户允许
enum ToolKind {
  read,

  /// 安装、启用或禁用、备份：可以在本次对话中允许同类操作
  write,

  /// 删除、替换、恢复：每次都要确认
  danger,
}

/// 准备好的操作：确认卡片显示 [title] 与 [details]，用户允许后执行 [run]
class ToolPlan {
  ToolPlan(this.title, this.run, {this.details = const []});

  final String title;
  final List<String> details;

  /// 返回给模型的执行结果
  final Future<String> Function() run;
}

class AiToolDef {
  const AiToolDef({required this.spec, required this.kind, required this.label, required this.prepare});

  final AiTool spec;
  final ToolKind kind;

  /// 简短的操作名，例如「安装模组」
  final String label;

  /// 校验参数并准备操作，不产生任何修改
  final Future<ToolPlan> Function(Map<String, dynamic> args) prepare;
}

class ToolError implements Exception {
  ToolError(this.message);

  final String message;

  @override
  String toString() => message;
}

const _versionParam = {'type': 'string', 'description': '版本名称（list_versions 返回的 id）'};

Map<String, dynamic> _schema(Map<String, dynamic> props, [List<String> required = const []]) => {
  'type': 'object',
  'properties': props,
  'required': required,
  'additionalProperties': false,
};

/// AI 可以使用的启动器操作。只开放这些固定操作，并且只能访问游戏文件夹中的内容；
/// 下载只通过 Modrinth API 解析，模型不能指定下载地址。
class AiToolbox {
  AiToolbox(this.state);

  final AppState state;

  late final List<AiToolDef> all = [
    AiToolDef(
      spec: AiTool('list_versions', '列出当前游戏文件夹中已安装的所有版本，以及当前选择的版本。', _schema({})),
      kind: ToolKind.read,
      label: '查看版本列表',
      prepare: (_) async => ToolPlan('查看版本列表', _listVersions),
    ),
    AiToolDef(
      spec: AiTool(
        'get_version_info',
        '查看一个版本的详细信息：加载器、Java 与内存设置、模组数量、存档列表、运行目录。',
        _schema({'version': _versionParam}, ['version']),
      ),
      kind: ToolKind.read,
      label: '查看版本信息',
      prepare: (a) async {
        final v = _version(a);
        return ToolPlan('查看 ${v.id} 的信息', () => _versionInfo(v));
      },
    ),
    AiToolDef(
      spec: AiTool('list_mods', '列出一个版本的模组文件（mods 文件夹），包括是否启用。', _schema({'version': _versionParam}, ['version'])),
      kind: ToolKind.read,
      label: '查看模组列表',
      prepare: (a) async {
        final v = _version(a);
        return ToolPlan('查看 ${v.id} 的模组', () => _listMods(v));
      },
    ),
    AiToolDef(
      spec: AiTool(
        'list_files',
        '列出一个版本运行目录中某个文件夹的内容（例如 config、saves、resourcepacks）。',
        _schema(
          {
            'version': _versionParam,
            'path': {'type': 'string', 'description': '相对于版本运行目录的文件夹路径，留空表示根目录'},
          },
          ['version'],
        ),
      ),
      kind: ToolKind.read,
      label: '查看文件',
      prepare: (a) async {
        final v = _version(a);
        final dir = await _gameDir(v);
        final rel = '${a['path'] ?? ''}'.trim();
        final abs = rel.isEmpty ? dir : _inside(dir, rel);
        // 文件夹不存在是正常的查看结果（例如还没有装光影），不算失败
        return ToolPlan('查看 ${v.id}/${rel.isEmpty ? '' : rel}', () async {
          _recheck(dir, abs);
          return Directory(abs).existsSync() ? _listDir(dir, abs) : '文件夹不存在：$rel';
        });
      },
    ),
    AiToolDef(
      spec: AiTool(
        'read_log',
        '读取一个版本的日志（已截取错误相关部分并去除隐私信息）。kind：latest 为最近一次的游戏日志，crash 为最新的崩溃报告，debug 为调试日志。',
        _schema(
          {
            'version': _versionParam,
            'kind': {
              'type': 'string',
              'enum': ['latest', 'crash', 'debug'],
            },
          },
          ['version', 'kind'],
        ),
      ),
      kind: ToolKind.read,
      label: '读取日志',
      prepare: (a) async {
        final v = _version(a);
        final kind = '${a['kind']}';
        return ToolPlan(
          '读取 ${v.id} 的${const {'crash': '崩溃报告', 'debug': '调试日志'}[kind] ?? '游戏日志'}',
          () => _readLog(v, kind),
        );
      },
    ),
    AiToolDef(
      spec: AiTool(
        'search_mods',
        '在 Modrinth 上搜索与某个版本兼容的模组，返回项目 ID、名称和简介。',
        _schema(
          {
            'query': {'type': 'string', 'description': '搜索关键词（英文名称效果最好）'},
            'version': _versionParam,
          },
          ['query', 'version'],
        ),
      ),
      kind: ToolKind.read,
      label: '搜索模组',
      prepare: (a) async {
        final v = _version(a);
        final q = '${a['query'] ?? ''}'.trim();
        if (q.isEmpty) throw ToolError('请提供搜索关键词');
        return ToolPlan('在 Modrinth 搜索「$q」', () => _search(v, q));
      },
    ),
    AiToolDef(
      spec: AiTool(
        'list_game_versions',
        '列出可以安装的 Minecraft Java 版版本，以及最新的正式版和快照。',
        _schema({
          'type': {
            'type': 'string',
            'enum': ['release', 'snapshot', 'all'],
            'description': '默认 release（正式版）',
          },
          'query': {'type': 'string', 'description': '可选：按版本号筛选，例如 1.20'},
        }),
      ),
      kind: ToolKind.read,
      label: '查看可安装的版本',
      prepare: (a) async =>
          ToolPlan('查看可安装的 Minecraft 版本', () => _gameVersions('${a['type'] ?? 'release'}', '${a['query'] ?? ''}')),
    ),
    AiToolDef(
      spec: AiTool(
        'list_loader_versions',
        '列出某个 Minecraft 版本可用的加载器版本（新的在前，标注推荐的稳定版）。'
            'loader 可选：${LoaderKind.values.map((k) => k.name).join('、')}。OptiFine 会注明需要的 Forge 版本。',
        _schema(
          {
            'game_version': {'type': 'string', 'description': 'Minecraft 版本号，例如 1.20.1'},
            'loader': {
              'type': 'string',
              'enum': [for (final k in LoaderKind.values) k.name],
            },
          },
          ['game_version', 'loader'],
        ),
      ),
      kind: ToolKind.read,
      label: '查看加载器版本',
      prepare: (a) async {
        final kind = _loaderKind(a['loader']);
        final game = '${a['game_version'] ?? ''}'.trim();
        if (kind == null) throw ToolError('不支持的加载器：${a['loader']}');
        return ToolPlan('查看 $game 的 ${kind.label} 版本', () => _loaderVersions(kind, game));
      },
    ),
    AiToolDef(
      spec: AiTool(
        'install_game',
        '安装一个 Minecraft 版本，可以同时安装加载器与 OptiFine，完成后会选中这个版本。'
            '不指定 loader 时安装原版；loader 为 optifine 时安装独立的 OptiFine 版本。'
            '不指定 loader_version 时使用推荐的稳定版。optifine 参数用于在 Forge、NeoForge、Fabric 等加载器上把 OptiFine 作为模组一起安装。'
            '安装需要下载较多文件，可能要几分钟。',
        _schema(
          {
            'game_version': {'type': 'string', 'description': 'Minecraft 版本号，例如 1.20.1'},
            'loader': {
              'type': 'string',
              'enum': [for (final k in LoaderKind.values) k.name],
            },
            'loader_version': {'type': 'string', 'description': 'list_loader_versions 返回的完整版本号'},
            'optifine': {'type': 'string', 'description': '可选：同时安装的 OptiFine 版本（list_loader_versions 返回的版本号）'},
            'name': {'type': 'string', 'description': '可选：版本名称，默认按加载器自动命名'},
          },
          ['game_version'],
        ),
      ),
      kind: ToolKind.write,
      label: '安装游戏版本',
      prepare: _prepareInstall,
    ),
    AiToolDef(
      spec: AiTool('select_version', '把启动页当前选择的版本切换为指定的已安装版本。', _schema({'version': _versionParam}, ['version'])),
      kind: ToolKind.write,
      label: '切换版本',
      prepare: (a) async {
        final v = _version(a);
        return ToolPlan('把当前版本切换为 ${v.id}', () async {
          await state.selectVersion(v.id);
          return '已切换为 ${v.id}';
        }, details: ['${v.id}（${describeVersion(v)}）']);
      },
    ),
    AiToolDef(
      spec: AiTool(
        'search_resources',
        '在 Modrinth 搜索资源：模组、光影包、资源包、数据包或整合包。可以用 game_version（例如 1.21.1）和 loader 筛选，'
            '不需要先安装那个版本；也可以用 version 指定已安装的版本。推荐资源时可以按下载量（downloads）或关注数（follows）排序。',
        _schema(
          {
            'type': {
              'type': 'string',
              'enum': [for (final t in ResourceType.values) t.tag],
            },
            'query': {'type': 'string', 'description': '关键词，可以为空（只按排序列出热门资源）'},
            'version': {'type': 'string', 'description': '可选：已安装的版本名称，按它的游戏版本和加载器筛选'},
            'game_version': {'type': 'string', 'description': '可选：游戏版本，例如 1.21.1；不需要先安装这个版本'},
            'loader': {
              'type': 'string',
              'enum': ['fabric', 'forge', 'neoforge', 'quilt'],
              'description': '可选：模组加载器（只对模组有效）',
            },
            'limit': {'type': 'integer', 'description': '结果数量，1–20，默认 12'},
            'sort': {
              'type': 'string',
              'enum': ['relevance', 'downloads', 'follows', 'newest', 'updated'],
            },
          },
          ['type'],
        ),
      ),
      kind: ToolKind.read,
      label: '搜索资源',
      prepare: (a) async {
        final type = _resourceType(a['type']);
        final f = _filter(a, type);
        final q = '${a['query'] ?? ''}'.trim();
        final sort = '${a['sort'] ?? 'relevance'}';
        final limit = ((a['limit'] as num?)?.toInt() ?? 12).clamp(1, 20);
        return ToolPlan(
          '在 Modrinth 搜索${f == null ? '' : '${f.label} 的'}${type.label}${q.isEmpty ? '' : '「$q」'}',
          () => _searchResources(type, q, f, sort, limit),
        );
      },
    ),
    AiToolDef(
      spec: AiTool(
        'get_project',
        '查看 Modrinth 项目：简介、分类、支持的游戏版本；指定 game_version / loader（或已安装的 version）时，'
            '给出是否支持、对应的最新版本和必需的前置。比较多个项目时用 projects 一次查完（最多 10 个，只返回摘要）。',
        _schema({
          'project': {'type': 'string', 'description': 'Modrinth 项目 ID 或 slug（查看一个项目的详情）'},
          'projects': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '多个项目 ID 或 slug（一次比较多个，最多 10 个）',
          },
            'version': {'type': 'string', 'description': '可选：已安装的版本名称，按它的游戏版本和加载器筛选'},
            'game_version': {'type': 'string', 'description': '可选：游戏版本，例如 1.21.1；不需要先安装这个版本'},
            'loader': {
              'type': 'string',
              'enum': ['fabric', 'forge', 'neoforge', 'quilt'],
              'description': '可选：模组加载器（只对模组有效）',
            },
        }),
      ),
      kind: ToolKind.read,
      label: '查看项目详情',
      prepare: (a) async {
        final ids = <String>{
          for (final x in (a['projects'] as List? ?? const [])) '$x'.trim(),
          '${a['project'] ?? ''}'.trim(),
        }..remove('');
        if (ids.isEmpty) throw ToolError('请提供项目 ID（project 或 projects）');
        if (ids.length > 10) throw ToolError('一次最多查看 10 个项目');
        final f = _filter(a, ResourceType.mod);
        if (ids.length == 1) return ToolPlan('查看 Modrinth 项目 ${ids.first}', () => _projectInfo(ids.first, f));
        return ToolPlan('比较 ${ids.length} 个 Modrinth 项目', () async {
          final rows = await Future.wait([
            for (final id in ids)
              _projectInfo(id, f, brief: true).catchError((Object e) => '- $id：查询失败（$e）'),
          ]);
          return rows.join('\n');
        });
      },
    ),
    AiToolDef(
      spec: AiTool(
        'install_resource',
        '从 Modrinth 安装光影包、资源包或数据包到一个版本（模组请用 install_mod）。数据包需要指定存档 world。'
            '默认选择与该版本兼容的最新正式版。光影包需要 Iris 或 OptiFine 才能使用。',
        _schema(
          {
            'version': _versionParam,
            'project': {'type': 'string', 'description': 'Modrinth 项目 ID 或 slug'},
            'type': {
              'type': 'string',
              'enum': ['shader', 'resourcepack', 'datapack'],
            },
            'mod_version_id': {'type': 'string', 'description': '可选：指定 Modrinth 的版本 ID'},
            'world': {'type': 'string', 'description': '数据包要安装到的存档名称'},
          },
          ['version', 'project', 'type'],
        ),
      ),
      kind: ToolKind.write,
      label: '安装资源',
      prepare: (a) async {
        final v = _version(a);
        final type = _resourceType(a['type']);
        if (type == ResourceType.mod || type == ResourceType.modpack) throw ToolError('模组请用 install_mod；暂不支持安装整合包');
        final dir = await _gameDir(v);
        final world = '${a['world'] ?? ''}'.trim();
        if (type == ResourceType.datapack && !worldsOf(dir).contains(world)) {
          throw ToolError('请指定存档。${v.id} 的存档：${worldsOf(dir).isEmpty ? '无' : worldsOf(dir).join('、')}');
        }
        final rv = await _resolveResource(
          v,
          type,
          '${a['project'] ?? ''}'.trim(),
          '${a['mod_version_id'] ?? ''}'.trim(),
        );
        final note = type == ResourceType.shader ? _shaderSupport(v, dir) : null;
        return ToolPlan(
          '安装${type.label} ${rv.name}',
          () async {
            final r = await state.installResource(rv, type, v, world: type == ResourceType.datapack ? world : null);
            return [
              if (r.installed.isNotEmpty) '已安装：${r.installed.join('、')}',
              if (r.skipped.isNotEmpty) '已存在，跳过：${r.skipped.join('、')}',
              ?note,
            ].join('；');
          },
          details: [
            '版本：${v.id}',
            '文件：${rv.fileName}（${_size(rv.fileSize)}），放进 ${type == ResourceType.datapack ? 'saves/$world/datapacks' : type.folder}',
            '来源：Modrinth',
            ?note,
          ],
        );
      },
    ),
    AiToolDef(
      spec: AiTool('list_javas', '列出启动器找到的 Java，以及全局设置使用的 Java。', _schema({})),
      kind: ToolKind.read,
      label: '查看 Java',
      prepare: (_) async => ToolPlan('查看已安装的 Java', _listJavas),
    ),
    AiToolDef(
      spec: AiTool('system_info', '查看系统信息：操作系统、内存、处理器与显卡（含驱动版本）。', _schema({})),
      kind: ToolKind.read,
      label: '查看系统信息',
      prepare: (_) async => ToolPlan('查看系统信息', _systemInfo),
    ),
    AiToolDef(
      spec: AiTool(
        'set_version_java',
        '设置某个版本使用的 Java。java 为 global（跟随全局设置）、auto（自动选择），或 list_javas 返回的 Java 路径。',
        _schema(
          {
            'version': _versionParam,
            'java': {'type': 'string'},
          },
          ['version', 'java'],
        ),
      ),
      kind: ToolKind.write,
      label: '设置版本的 Java',
      prepare: (a) async {
        final v = _version(a);
        final arg = '${a['java'] ?? ''}'.trim();
        final JavaPref pref;
        String label;
        if (arg == 'global') {
          pref = const JavaGlobal();
          label = '跟随全局设置';
        } else if (arg == 'auto') {
          pref = const JavaAuto();
          label = '自动选择';
        } else {
          // 只能选择启动器找到的 Java，不能指定任意程序
          final j = (await state.javas()).where((j) => p.equals(j.path, arg)).firstOrNull;
          if (j == null) throw ToolError('不是启动器找到的 Java：$arg，请先用 list_javas 查看');
          pref = JavaExist(j.path);
          label = 'Java ${j.major}（${state.redactor().apply(j.path)}）';
        }
        final old = _javaLabel(readInstanceSettings(state.paths.versionDir(v.id)).java);
        return ToolPlan('把 ${v.id} 的 Java 改为$label', () async {
          await writeInstanceJava(state.paths.versionDir(v.id), pref);
          return '已把 ${v.id} 的 Java 设为$label';
        }, details: ['版本：${v.id}', '原来：$old', '改为：$label']);
      },
    ),
    AiToolDef(
      spec: AiTool(
        'set_version_memory',
        '设置某个版本的内存。mode 为 global（跟随全局设置）、auto（自动分配）或 custom（自定义，需要 max_gb）。',
        _schema(
          {
            'version': _versionParam,
            'mode': {
              'type': 'string',
              'enum': ['global', 'auto', 'custom'],
            },
            'max_gb': {'type': 'number', 'description': 'custom 时的最大内存（GB）'},
          },
          ['version', 'mode'],
        ),
      ),
      kind: ToolKind.write,
      label: '设置版本的内存',
      prepare: (a) async {
        final v = _version(a);
        final mode = '${a['mode'] ?? ''}';
        if (!const {'global', 'auto', 'custom'}.contains(mode)) throw ToolError('mode 只能是 global、auto 或 custom');
        final mem = systemMemory();
        var tick = 0;
        if (mode == 'custom') {
          final gb = (a['max_gb'] as num?)?.toDouble();
          if (gb == null || gb < 0.5) throw ToolError('请提供 max_gb（至少 0.5）');
          // 不超过系统总内存（与版本设置页的滑块范围一致）
          if (gb > mem.total) throw ToolError('超过了系统总内存 ${mem.total.toStringAsFixed(1)} GB');
          tick = 1;
          while (tick < maxTickFor(mem.total) && ramFromTick(tick + 1) <= gb) {
            tick++;
          }
        }
        final s = readInstanceSettings(state.paths.versionDir(v.id));
        final label = switch (mode) {
          'custom' => '自定义 ${ramFromTick(tick).toStringAsFixed(1)} GB',
          'auto' => '自动分配',
          _ => '跟随全局设置',
        };
        return ToolPlan(
          '把 ${v.id} 的内存改为$label',
          () async {
            await writeInstanceRaw(state.paths.versionDir(v.id), {
              'VersionRamType': const {'auto': 0, 'custom': 1, 'global': 2}[mode]!,
              if (mode == 'custom') 'VersionRamCustom': tick,
            });
            return '已把 ${v.id} 的内存设为$label';
          },
          details: [
            '版本：${v.id}',
            '原来：${_memoryLabel(s)}',
            '改为：$label',
            '系统内存：共 ${mem.total.toStringAsFixed(1)} GB，当前空闲 ${mem.free.toStringAsFixed(1)} GB',
          ],
        );
      },
    ),
    AiToolDef(
      spec: AiTool(
        'read_config',
        '读取一个版本的配置文件（config 文件夹中的文本文件，或 options.txt 等游戏选项文件）。',
        _schema(
          {
            'version': _versionParam,
            'path': {'type': 'string', 'description': '相对于版本运行目录的路径，例如 config/sodium-options.json'},
          },
          ['version', 'path'],
        ),
      ),
      kind: ToolKind.read,
      label: '读取配置文件',
      prepare: (a) async {
        final v = _version(a);
        final (abs, rel) = await _configFile(v, a['path']);
        return ToolPlan('读取 $rel', () async {
          _recheck(await _gameDir(v), abs);
          final text = await File(abs).readAsString();
          return state.redactor().apply(
            text.length > 30000 ? '${text.substring(0, 30000)}\n…（文件过长，只显示前 30000 个字符）' : text,
          );
        });
      },
    ),
    AiToolDef(
      spec: AiTool(
        'edit_config',
        '修改一个版本的配置文件：把文件中的一段原文替换为新内容，可以一次做多处替换。每段原文必须在文件中只出现一次。修改前会自动备份。',
        _schema(
          {
            'version': _versionParam,
            'path': {'type': 'string', 'description': '相对于版本运行目录的路径'},
            'edits': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'old': {'type': 'string', 'description': '文件中的原文（原样复制）'},
                  'new': {'type': 'string', 'description': '替换后的内容'},
                },
                'required': ['old', 'new'],
                'additionalProperties': false,
              },
            },
          },
          ['version', 'path', 'edits'],
        ),
      ),
      kind: ToolKind.danger,
      label: '修改配置文件',
      prepare: (a) async {
        final v = _version(a);
        final (abs, rel) = await _configFile(v, a['path']);
        final edits = [
          for (final e in (a['edits'] is List ? a['edits'] as List : const []).whereType<Map>())
            (old: '${e['old'] ?? ''}', now: '${e['new'] ?? ''}'),
        ];
        if (edits.isEmpty) throw ToolError('请提供要修改的内容');
        var text = await File(abs).readAsString();
        for (final e in edits) {
          if (e.old.isEmpty) throw ToolError('原文不能为空');
          final n = e.old.allMatches(text).length;
          if (n != 1) throw ToolError(n == 0 ? '文件中找不到原文：${e.old}' : '原文在文件中出现了 $n 次，请提供更长、唯一的原文：${e.old}');
          text = text.replaceFirst(e.old, e.now);
        }
        final result = text;
        String clip(String s) => s.length > 200 ? '${s.substring(0, 200)}…' : s;
        return ToolPlan(
          '修改 $rel（${edits.length} 处）',
          () async {
            final dir = await _gameDir(v);
            _recheck(dir, abs);
            final zip = await _backup(v, dir, [rel], 'config');
            await File(abs).writeAsString(result);
            return '已修改 $rel，原文件已备份到 ${p.basename(zip)}';
          },
          details: [
            '版本：${v.id}',
            for (final e in edits) ...[
              for (final l in clip(e.old).split('\n')) '- $l',
              for (final l in clip(e.now).split('\n')) '+ $l',
            ],
            '修改前会备份原文件',
          ],
        );
      },
    ),
    AiToolDef(
      spec: AiTool(
        'install_mod',
        '从 Modrinth 安装模组到一个版本，会一并安装必需的前置模组。默认选择与该版本兼容的最新正式版。',
        _schema(
          {
            'version': _versionParam,
            'project': {'type': 'string', 'description': 'Modrinth 项目 ID 或 slug'},
            'mod_version_id': {'type': 'string', 'description': '可选：指定 Modrinth 的版本 ID'},
          },
          ['version', 'project'],
        ),
      ),
      kind: ToolKind.write,
      label: '安装模组',
      prepare: (a) async {
        final v = _version(a);
        final mv = await _resolveMod(v, a);
        return ToolPlan(
          '安装模组 ${mv.name}',
          () => _install(v, mv),
          details: [
            '版本：${v.id}',
            '文件：${mv.fileName}（${_size(mv.fileSize)}）',
            '来源：Modrinth',
            if (mv.requires.isNotEmpty) '会同时安装必需的前置模组',
          ],
        );
      },
    ),
    AiToolDef(
      spec: AiTool(
        'set_mods_enabled',
        '启用或禁用一个版本中的模组（与 PCL 相同，禁用时在文件名后加 .disabled）。',
        _schema(
          {
            'version': _versionParam,
            'files': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'mods 文件夹中的文件名',
            },
            'enabled': {'type': 'boolean'},
          },
          ['version', 'files', 'enabled'],
        ),
      ),
      kind: ToolKind.write,
      label: '启用或禁用模组',
      prepare: (a) async {
        final v = _version(a);
        final enabled = a['enabled'] == true;
        final files = await _modFiles(v, a['files']);
        return ToolPlan('${enabled ? '启用' : '禁用'} ${files.length} 个模组', () async {
          final dir = await _gameDir(v);
          for (final f in files) {
            _recheck(dir, f.path);
            await setModEnabled(f, enabled);
          }
          return '已${enabled ? '启用' : '禁用'}：${files.map((f) => f.name).join('、')}';
        }, details: ['版本：${v.id}', for (final f in files) f.name]);
      },
    ),
    AiToolDef(
      spec: AiTool(
        'backup',
        '把一个版本运行目录中的文件或文件夹（例如 saves/世界名、mods、config）打包备份。',
        _schema(
          {
            'version': _versionParam,
            'paths': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '相对于版本运行目录的路径',
            },
            'label': {'type': 'string', 'description': '可选：备份的简短说明，用于文件名'},
          },
          ['version', 'paths'],
        ),
      ),
      kind: ToolKind.write,
      label: '备份',
      prepare: (a) async {
        final v = _version(a);
        final dir = await _gameDir(v);
        final paths = _existing(dir, a['paths']);
        final size = paths.fold<int>(0, (s, e) => s + _sizeOf(p.join(dir, e)));
        return ToolPlan('备份 ${paths.length} 项', () async {
          final zip = await _backup(v, dir, paths, '${a['label'] ?? ''}');
          return '已备份到 ${p.basename(zip)}';
        }, details: ['版本：${v.id}', ...paths, '大小约 ${_size(size)}，保存到游戏文件夹的 backups 中']);
      },
    ),
    AiToolDef(
      spec: AiTool('list_backups', '列出一个版本的备份及其包含的内容。', _schema({'version': _versionParam}, ['version'])),
      kind: ToolKind.read,
      label: '查看备份',
      prepare: (a) async {
        final v = _version(a);
        return ToolPlan('查看 ${v.id} 的备份', () => _listBackups(v));
      },
    ),
    AiToolDef(
      spec: AiTool(
        'delete_files',
        '删除一个版本运行目录中的文件或文件夹。文件会移到回收站，可以从回收站恢复。',
        _schema(
          {
            'version': _versionParam,
            'paths': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '相对于版本运行目录的路径，例如 mods/xxx.jar',
            },
          },
          ['version', 'paths'],
        ),
      ),
      kind: ToolKind.danger,
      label: '删除文件',
      prepare: (a) async {
        final v = _version(a);
        final dir = await _gameDir(v);
        final paths = _existing(dir, a['paths']);
        return ToolPlan('删除 ${paths.length} 项（移到回收站）', () async {
          for (final rel in paths) {
            await moveToTrash(_inside(dir, rel));
          }
          return '已移到回收站：${paths.join('、')}';
        }, details: ['版本：${v.id}', for (final rel in paths) '$rel（${_size(_sizeOf(p.join(dir, rel)))}）']);
      },
    ),
    AiToolDef(
      spec: AiTool(
        'replace_mod',
        '用 Modrinth 上的另一个版本替换一个模组文件：先备份旧文件，再把旧文件移到回收站，然后安装新版本。',
        _schema(
          {
            'version': _versionParam,
            'file': {'type': 'string', 'description': 'mods 文件夹中要替换的文件名'},
            'project': {'type': 'string', 'description': 'Modrinth 项目 ID 或 slug'},
            'mod_version_id': {'type': 'string', 'description': '可选：指定 Modrinth 的版本 ID'},
          },
          ['version', 'file', 'project'],
        ),
      ),
      kind: ToolKind.danger,
      label: '替换模组',
      prepare: (a) async {
        final v = _version(a);
        final old = (await _modFiles(v, [a['file']])).single;
        final mv = await _resolveMod(v, a);
        if (mv.fileName == old.name.replaceFirst(RegExp(r'\.disabled$'), '')) throw ToolError('新旧文件相同，不需要替换');
        return ToolPlan('替换模组 ${old.name}', () async {
          final dir = await _gameDir(v);
          _recheck(dir, old.path);
          final rel = p.relative(old.path, from: dir).replaceAll('\\', '/');
          final zip = await _backup(v, dir, [rel], 'replace');
          await moveToTrash(old.path);
          final r = await _install(v, mv);
          return '旧文件已备份到 ${p.basename(zip)} 并移到回收站。$r';
        }, details: ['版本：${v.id}', '旧文件：${old.name}', '新文件：${mv.fileName}（${mv.name}，来自 Modrinth）', '旧文件会先备份，再移到回收站']);
      },
    ),
    AiToolDef(
      spec: AiTool(
        'restore_backup',
        '从备份恢复：先把当前的对应内容备份并移到回收站，再解压备份。',
        _schema(
          {
            'version': _versionParam,
            'backup': {'type': 'string', 'description': 'list_backups 返回的备份文件名'},
          },
          ['version', 'backup'],
        ),
      ),
      kind: ToolKind.danger,
      label: '从备份恢复',
      prepare: (a) async {
        final v = _version(a);
        final name = p.basename('${a['backup'] ?? ''}');
        final zip = p.join(_backupDir(v), name);
        if (!name.endsWith('.zip') || FileSystemEntity.typeSync(zip, followLinks: false) != FileSystemEntityType.file) {
          throw ToolError('找不到备份：$name');
        }
        final dir = await _gameDir(v);
        // 恢复前完整检查一遍：清单与每个条目的路径、签名、内容摘要
        final BackupCheck check;
        try {
          check = await checkBackup(zip, dir, _backupKey());
        } on BackupException catch (e) {
          throw ToolError(e.message);
        }
        for (final rel in check.paths) {
          _inside(dir, rel);
        }
        return ToolPlan(
          '从备份 $name 恢复',
          () => _restore(v, dir, zip, check),
          details: [
            '版本：${v.id}',
            '将恢复：${check.paths.join('、')}（${check.files} 个文件，${_size(check.bytes)}）',
            if (!check.signed) '注意：这是旧版 Pixel World 创建的备份，没有签名，无法确认内容未被修改过',
            '先解压到临时文件夹并校验，成功后才把当前的对应内容备份并移到回收站',
          ],
        );
      },
    ),
    ...workspaceTools(state),
    ...webTools(state),
  ];

  // 按内置服务分组（见 mcp_hub.dart）：游戏管理、AI 工作区、联网搜索。
  // 对话不直接调用这里的操作，统一经 McpHub 调用；工作区与联网关闭后，对应的服务不提供给模型
  static bool _isWorkspace(AiToolDef t) => t.spec.name.startsWith('ws_');
  static bool _isWeb(AiToolDef t) => t.spec.name.startsWith('web_') || t.spec.name == 'mcwiki_search';

  List<AiToolDef> get gameDefs => [for (final t in all) if (!_isWorkspace(t) && !_isWeb(t)) t];
  List<AiToolDef> get workspaceDefs => [for (final t in all) if (_isWorkspace(t)) t];
  List<AiToolDef> get webDefs => [for (final t in all) if (_isWeb(t)) t];

  // ---------- 安装游戏 ----------

  static LoaderKind? _loaderKind(Object? v) {
    final s = '${v ?? ''}'.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');
    if (s.isEmpty) return null;
    return LoaderKind.values.where((k) => k.name == s).firstOrNull;
  }

  Future<String> _gameVersions(String type, String query) async {
    final r = await remoteVersions(state.downloader);
    final q = query.trim();
    final list = r.list.where((v) {
      if (q.isNotEmpty && !v.id.contains(q)) return false;
      return switch (type) {
        'snapshot' => v.type == 'snapshot',
        'all' => true,
        _ => v.type == 'release',
      };
    }).toList();
    return [
      '最新正式版：${r.latestRelease}，最新快照：${r.latestSnapshot}',
      if (list.isEmpty) '没有符合条件的版本',
      for (final v in list.take(60)) '- ${v.id}（${v.type}${v.fool ? '，愚人节版本' : ''}，${v.releaseTime.split('T').first}）',
      if (list.length > 60) '……共 ${list.length} 个，只列出最新的 60 个，可以用 query 筛选',
    ].join('\n');
  }

  Future<String> _loaderVersions(LoaderKind kind, String game) async {
    final list = await loaderVersions(state.downloader, kind, game);
    if (list.isEmpty) return '${kind.label} 没有适用于 $game 的版本';
    final recommended = list.where((v) => v.stable).firstOrNull ?? list.first;
    return [
      '推荐：${recommended.version}',
      for (final v in list.take(30))
        '- ${v.version}${v.stable ? '' : '（测试版）'}'
            '${kind == LoaderKind.optifine ? (v.requiredForge == null
                      ? '，不兼容 Forge'
                      : v.requiredForge!.isEmpty
                      ? ''
                      : '，需要 Forge ${v.requiredForge}') : ''}',
      if (list.length > 30) '……共 ${list.length} 个，只列出最新的 30 个',
    ].join('\n');
  }

  Future<ToolPlan> _prepareInstall(Map<String, dynamic> a) async {
    final game = '${a['game_version'] ?? ''}'.trim();
    if (game.isEmpty) throw ToolError('请提供 Minecraft 版本号');
    final remote = await remoteVersions(state.downloader);
    final rv = remote.list.where((v) => v.id == game).firstOrNull;
    if (rv == null) throw ToolError('没有名为 $game 的 Minecraft 版本，可以先用 list_game_versions 查看');

    final loaderArg = '${a['loader'] ?? ''}'.trim();
    final kind = loaderArg.isEmpty || loaderArg == 'vanilla' ? null : _loaderKind(loaderArg);
    if (loaderArg.isNotEmpty && loaderArg != 'vanilla' && kind == null) throw ToolError('不支持的加载器：$loaderArg');

    // 加载器版本：指定的必须存在；没有指定时用推荐的稳定版
    var loaderVersion = '';
    if (kind != null) {
      final list = await loaderVersions(state.downloader, kind, game);
      if (list.isEmpty) throw ToolError('${kind.label} 没有适用于 $game 的版本');
      final wanted = '${a['loader_version'] ?? ''}'.trim();
      final pick = wanted.isEmpty
          ? (list.where((v) => v.stable).firstOrNull ?? list.first)
          : list.where((v) => v.version == wanted || v.label == wanted).firstOrNull;
      if (pick == null) throw ToolError('${kind.label} 没有版本 $wanted，可以先用 list_loader_versions 查看');
      loaderVersion = pick.version;
    }

    // OptiFine 作为模组一起安装（与 PCL 相同）
    final ofArg = '${a['optifine'] ?? ''}'.trim();
    String? optifine;
    if (ofArg.isNotEmpty) {
      if (kind == LoaderKind.optifine) throw ToolError('loader 已经是 optifine，不需要再指定 optifine');
      if (!canAddOptiFine(loaderOfKind(kind))) throw ToolError('${kind?.label ?? '原版'} 不能与 OptiFine 一起安装');
      final list = await loaderVersions(state.downloader, LoaderKind.optifine, game);
      final of = list.where((v) => v.version == ofArg || v.label == ofArg).firstOrNull;
      if (of == null) throw ToolError('OptiFine 没有适用于 $game 的版本 $ofArg');
      if (kind == LoaderKind.forge && of.requiredForge == null) throw ToolError('OptiFine $ofArg 不兼容 Forge');
      optifine = of.version;
    }

    final nameArg = '${a['name'] ?? ''}'.trim();
    final name = nameArg.isEmpty ? null : nameArg;
    final shown = name ?? defaultVersionName(kind, game, loaderVersion);
    try {
      // 由官方安装器命名的加载器（Forge 等）只在指定名称时检查
      if (name != null || kind == null || kind == LoaderKind.fabric || kind == LoaderKind.quilt) {
        checkVersionName(state.paths, shown);
      }
    } catch (e) {
      throw ToolError(errorMessage(e));
    }

    return ToolPlan(
      '安装 $shown',
      () async {
        final id = await state.installVersion(
          game,
          loader: kind,
          loaderVersion: loaderVersion,
          name: name,
          optifine: optifine,
        );
        return '已安装为 $id，并已设为当前选择的版本';
      },
      details: [
        'Minecraft $game（${rv.type == 'release' ? '正式版' : rv.type}）',
        if (kind != null) loaderComponent(kind, game, loaderVersion),
        if (optifine != null)
          '${loaderComponent(LoaderKind.optifine, game, optifine)}（${optiFineNote(loaderOfKind(kind), null)}）',
        '版本名称：$shown',
        '从${state.config.downloadSource == 'bmclapi' ? ' BMCLAPI 镜像' : '官方源'}下载，可能需要几分钟；进度可以在任务页查看',
      ],
    );
  }

  static String errorMessage(Object e) => '$e'.replaceFirst(RegExp(r'^Exception: ?'), '');

  // ---------- Modrinth 资源 ----------

  static ResourceType _resourceType(Object? v) =>
      ResourceType.values.where((t) => t.tag == '$v').firstOrNull ?? (throw ToolError('不支持的资源类型：$v'));

  /// 兼容性筛选：已安装的版本（version）优先，否则用 game_version + loader，不需要先安装那个版本
  ({String? gameVersion, List<String> loaders, String label})? _filter(Map<String, dynamic> a, ResourceType type) {
    if ('${a['version'] ?? ''}'.trim().isNotEmpty) {
      final v = _version(a);
      final loaders = modrinthLoaders(v.loader);
      if (type == ResourceType.mod && loaders.isEmpty && a['projects'] == null && a['project'] == null) {
        throw ToolError('${v.id} 不能安装模组（没有模组加载器）');
      }
      return (gameVersion: v.gameVersion, loaders: loaders, label: '${v.id}（${v.gameVersion}）');
    }
    final gv = '${a['game_version'] ?? ''}'.trim();
    final loader = '${a['loader'] ?? ''}'.trim().toLowerCase();
    if (gv.isEmpty && loader.isEmpty) return null;
    return (
      gameVersion: gv.isEmpty ? null : gv,
      loaders: loader.isEmpty ? const <String>[] : [loader],
      label: [if (gv.isNotEmpty) gv, if (loader.isNotEmpty) loader].join(' '),
    );
  }

  Future<String> _searchResources(
    ResourceType type,
    String q,
    ({String? gameVersion, List<String> loaders, String label})? f,
    String sort,
    int limit,
  ) async {
    final loader = type == ResourceType.mod ? f?.loaders.firstOrNull : null;
    final r = await Modrinth.search(type: type, query: q, gameVersion: f?.gameVersion, loader: loader, sort: sort);
    if (r.hits.isEmpty) return '没有找到结果${f == null ? '' : '（已筛选 ${f.label}）'}';
    return [
      if (f != null) '已筛选与 ${f.label} 兼容的结果，共 ${r.total} 个：',
      for (final h in r.hits.take(limit))
        '- ${h.title}（项目 ID：${h.id}，下载 ${h.downloads} 次，关注 ${h.follows}，分类：${h.categories.take(5).join('/')}）：'
            '${h.description.length > 120 ? '${h.description.substring(0, 120)}…' : h.description}',
    ].join('\n');
  }

  /// 项目信息；[brief] 时只给一行摘要（比较多个项目时用）
  Future<String> _projectInfo(
    String project,
    ({String? gameVersion, List<String> loaders, String label})? f, {
    bool brief = false,
  }) async {
    final info = await Modrinth.project(project, ResourceType.mod);
    String? compat;
    if (f != null) {
      final list = await Modrinth.versions(project, gameVersion: f.gameVersion);
      // 模组按加载器筛选；光影、资源包等不区分加载器
      final compatible = list
          .where((x) => f.loaders.isEmpty || x.loaders.any(f.loaders.contains) || !x.loaders.any(_modLoaderTags.contains))
          .toList();
      String describe(ResourceVersion x) =>
          '${x.versionNumber}（${x.type}，${x.loaders.join('/')}，版本 ID ${x.id}'
          '${x.requires.isEmpty ? '' : '，必需前置的项目 ID：${x.requires.join('、')}'}）';
      compat = compatible.isEmpty
          ? '不支持 ${f.label}'
          : '支持 ${f.label}，最新：${compatible.take(brief ? 1 : 3).map(describe).join('；')}';
    }
    if (brief) {
      return '- ${info.hit.title}（项目 ID：${info.hit.id}，下载 ${info.hit.downloads} 次）：${compat ?? '支持 ${info.gameVersions.reversed.take(5).join('、')} 等'}';
    }
    final body = info.body.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)|<[^>]+>'), '').trim();
    return [
      '${info.hit.title}（项目 ID：${info.hit.id}，作者 ${info.hit.author}，下载 ${info.hit.downloads} 次）',
      '简介：${info.hit.description}',
      '分类：${info.hit.categories.join('、')}',
      '页面：${info.page}',
      '支持的游戏版本（最新的 10 个）：${info.gameVersions.reversed.take(10).join('、')}',
      ?compat,
      '说明（节选）：${body.length > 1500 ? '${body.substring(0, 1500)}…' : body}',
    ].join('\n');
  }

  static const _modLoaderTags = {'fabric', 'forge', 'neoforge', 'quilt', 'legacy-fabric', 'liteloader'};

  Future<ResourceVersion> _resolveResource(InstanceInfo v, ResourceType type, String project, String wanted) async {
    if (project.isEmpty) throw ToolError('请提供 Modrinth 项目 ID');
    final list = await Modrinth.versions(project, gameVersion: v.gameVersion);
    final pick = wanted.isNotEmpty
        ? list.where((x) => x.id == wanted).firstOrNull
        : list.where((x) => x.type == 'release').firstOrNull ?? list.firstOrNull;
    if (pick == null) throw ToolError('$project 没有适用于 ${v.gameVersion} 的版本');
    return pick;
  }

  /// 光影包需要 Iris 或 OptiFine
  String? _shaderSupport(InstanceInfo v, String dir) {
    if (v.optifine) return null;
    final mods = listInstanceFiles(dir, InstanceFolder.mods).where((f) => !f.disabled).map((f) => f.name.toLowerCase());
    if (mods.any((n) => n.startsWith('iris') || n.contains('optifine') || n.startsWith('oculus'))) return null;
    return '注意：${v.id} 中没有找到 Iris 或 OptiFine，光影包需要它们才能使用';
  }

  // ---------- Java、内存与系统 ----------

  String _javaLabel(JavaPref j) => switch (j) {
    JavaGlobal() => '跟随全局设置',
    JavaAuto() => '自动选择',
    JavaExist(:final path) || JavaRelative(:final path) => state.redactor().apply(path),
  };

  String _memoryLabel(InstanceSettings s) => switch (s.memoryMode) {
    'custom' => '自定义 ${ramFromTick(s.memoryTick).toStringAsFixed(1)} GB',
    'auto' => '自动分配',
    _ => '跟随全局设置',
  };

  Future<String> _listJavas() async {
    final list = await state.javas();
    final r = state.redactor();
    final global = state.config.javaPath;
    return [
      '全局设置：${global.isEmpty ? '自动选择' : r.apply(global)}',
      if (list.isEmpty) '没有找到 Java（启动时会按需自动下载）',
      for (final j in list)
        '- Java ${j.major}（${j.version}，${j.is64 ? 64 : 32} 位${j.managed ? '，启动器下载' : ''}）：${r.apply(j.path)}',
      // 安卓上只能使用启动器提供的安卓版 Java
      if (Platform.isAndroid) ...[
        '（安卓版只能使用启动器提供的 Java 8 / 17 / 21 / 25，可以在设置的 Java 页面下载或删除）',
        if (androidJavaMajors.any((m) => androidJavaAt(androidJavaHome(m)) == null))
          '未安装：${androidJavaMajors.where((m) => androidJavaAt(androidJavaHome(m)) == null).map((m) => 'Java $m').join('、')}'
              '（自动选择时会按需下载）',
      ],
    ].join('\n');
  }

  Future<String> _systemInfo() async {
    final mem = systemMemory();
    final env = Platform.environment;
    final lines = [
      '系统：${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      '内存：共 ${mem.total.toStringAsFixed(1)} GB，当前空闲 ${mem.free.toStringAsFixed(1)} GB',
      '处理器：${env['PROCESSOR_IDENTIFIER'] ?? '未知'}，${Platform.numberOfProcessors} 个逻辑核心',
    ];
    if (Platform.isWindows) {
      // 固定的查询命令，只读取显卡名称与驱动版本
      try {
        final r = await Process.run('powershell.exe', [
          '-NoProfile',
          '-Command',
          'Get-CimInstance Win32_VideoController | ForEach-Object { "\$(\$_.Name)|\$(\$_.DriverVersion)|\$(\$_.DriverDate)" }',
        ]).timeout(const Duration(seconds: 15));
        for (final l in '${r.stdout}'.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty)) {
          final parts = l.split('|');
          final date = parts.length > 2 && parts[2].length >= 8 ? parts[2].substring(0, 8) : '';
          lines.add(
            '显卡：${parts[0].trim()}，驱动 ${parts.length > 1 ? parts[1].trim() : '未知'}${date.isEmpty ? '' : '（$date）'}',
          );
        }
      } catch (_) {
        lines.add('显卡：无法读取');
      }
    }
    return lines.join('\n');
  }

  /// 配置文件：只允许 config 文件夹中的文件与 options*.txt，且必须是不太大的文本文件
  Future<(String, String)> _configFile(InstanceInfo v, Object? path) async {
    final dir = await _gameDir(v);
    final abs = _inside(dir, '${path ?? ''}');
    final rel = p.relative(abs, from: dir).replaceAll('\\', '/');
    final allowed = rel.startsWith('config/') || RegExp(r'^options[\w-]*\.txt$').hasMatch(rel);
    if (!allowed) throw ToolError('只能读写 config 文件夹中的文件和 options*.txt：$rel');
    if (!File(abs).existsSync()) throw ToolError('文件不存在：$rel');
    if (File(abs).lengthSync() > 1 << 20) throw ToolError('文件太大：$rel');
    final bytes = await File(abs).readAsBytes();
    if (bytes.take(4096).contains(0)) throw ToolError('不是文本文件：$rel');
    return (abs, rel);
  }

  // ---------- 辅助 ----------

  InstanceInfo _version(Map<String, dynamic> a) {
    final id = '${a['version'] ?? ''}'.trim();
    final v = state.instance(id);
    if (v == null) {
      throw ToolError('找不到版本「$id」。已安装的版本：${state.versions.map((v) => v.id).join('、')}');
    }
    return v;
  }

  Future<String> _gameDir(InstanceInfo v) => state.gameDirOf(v);

  /// 相对路径转为绝对路径，并确认在运行目录内（统一由 [resolveInside] 校验，包括符号链接）
  static String _inside(String dir, String rel) {
    try {
      return resolveInside(dir, rel);
    } on UnsafePathException catch (e) {
      throw ToolError(e.message);
    }
  }

  /// 执行前再确认一次：用户确认操作可能隔了很久，期间文件可能被替换成链接
  static void _recheck(String dir, String abs) {
    if (p.equals(dir, abs)) return;
    try {
      recheckInside(dir, abs);
    } on UnsafePathException catch (e) {
      throw ToolError(e.message);
    }
  }

  /// 校验路径列表并返回规范化的相对路径；去掉重复的和被其他路径包含的
  List<String> _existing(String dir, Object? list) {
    final items = (list is List ? list : const []).map((e) => '$e').where((e) => e.trim().isNotEmpty).toList();
    if (items.isEmpty) throw ToolError('请提供路径');
    final rels = [
      for (final rel in items)
        () {
          final abs = _inside(dir, rel);
          if (FileSystemEntity.typeSync(abs, followLinks: false) == FileSystemEntityType.notFound) {
            throw ToolError('文件不存在：$rel');
          }
          return p.relative(abs, from: dir).replaceAll('\\', '/');
        }(),
    ];
    return normalizePathSet(rels);
  }

  Future<List<InstanceFile>> _modFiles(InstanceInfo v, Object? list) async {
    final names = (list is List ? list : const []).map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList();
    if (names.isEmpty) throw ToolError('请提供模组文件名');
    final dir = await _gameDir(v);
    final mods = listInstanceFiles(dir, InstanceFolder.mods);
    return [
      for (final n in names)
        () {
          final m =
              mods.where((m) => m.name == n || m.name == '$n.disabled' || '${m.name}.disabled' == n).firstOrNull ??
              (throw ToolError('mods 文件夹中没有 $n'));
          _inside(dir, p.relative(m.path, from: dir));
          return m;
        }(),
    ];
  }

  Future<ResourceVersion> _resolveMod(InstanceInfo v, Map<String, dynamic> a) async {
    final project = '${a['project'] ?? ''}'.trim();
    if (project.isEmpty) throw ToolError('请提供 Modrinth 项目 ID');
    final loaders = modrinthLoaders(v.loader);
    if (loaders.isEmpty) throw ToolError('${v.id} 不能安装模组（没有模组加载器）');
    final list = await Modrinth.versions(project, gameVersion: v.gameVersion, loaders: loaders);
    final wanted = '${a['mod_version_id'] ?? ''}'.trim();
    final pick = wanted.isNotEmpty
        ? list.where((x) => x.id == wanted).firstOrNull
        : list.where((x) => x.type == 'release').firstOrNull ?? list.firstOrNull;
    if (pick == null) {
      throw ToolError(
        wanted.isNotEmpty
            ? '版本 $wanted 不存在，或与 ${v.id} 不兼容'
            : '$project 没有适用于 ${v.gameVersion}（${loaders.join('/')}）的版本',
      );
    }
    return pick;
  }

  Future<String> _install(InstanceInfo v, ResourceVersion mv) async {
    final r = await state.installResource(mv, ResourceType.mod, v);
    return [
      if (r.installed.isNotEmpty) '已安装：${r.installed.join('、')}',
      if (r.skipped.isNotEmpty) '已存在，跳过：${r.skipped.join('、')}',
      if (r.missing.isNotEmpty) '找不到兼容版本的前置：${r.missing.join('、')}',
    ].join('；');
  }

  static String _size(int b) => b >= 1 << 20
      ? '${(b / (1 << 20)).toStringAsFixed(1)} MB'
      : b >= 1024
      ? '${(b / 1024).toStringAsFixed(0)} KB'
      : '$b B';

  static int _sizeOf(String path) {
    final t = FileSystemEntity.typeSync(path);
    if (t == FileSystemEntityType.file) return File(path).lengthSync();
    if (t != FileSystemEntityType.directory) return 0;
    var n = 0;
    for (final e in Directory(path).listSync(recursive: true, followLinks: false)) {
      if (e is File) n += e.lengthSync();
    }
    return n;
  }

  // ---------- 只读操作 ----------

  Future<String> _listVersions() async {
    if (state.versions.isEmpty) return '当前游戏文件夹中没有已安装的版本';
    return [
      for (final v in state.versions)
        '- ${v.id}：${describeVersion(v)}${v.id == state.config.selectedVersion ? '（当前选择）' : ''}',
    ].join('\n');
  }

  Future<String> _versionInfo(InstanceInfo v) async {
    final dir = await _gameDir(v);
    final s = readInstanceSettings(state.paths.versionDir(v.id));
    final mods = listInstanceFiles(
      dir,
      InstanceFolder.mods,
    ).where((f) => f.name.endsWith('.jar') || f.disabled).toList();
    final worlds = worldsOf(dir);
    final resolved = await resolveVersion(state.paths, v.id).then<VersionJson?>((j) => j).catchError((_) => null);
    final required = resolved?.javaMajor ?? 8;
    // 指定的 Java 版本过高时（例如 Forge 1.12.2 用 Java 17）附上提醒，方便分析崩溃
    final chosen = switch (s.java) {
      JavaExist(:final path) ||
      JavaRelative(:final path) => (await state.javas()).where((j) => p.equals(j.path, path)).firstOrNull,
      _ => null,
    };
    final tooNew = resolved == null || chosen == null ? null : javaTooNewWarning(resolved, chosen.major);
    final java = switch (s.java) {
      JavaGlobal() => '跟随全局设置',
      JavaAuto() => '自动选择',
      JavaExist(:final path) || JavaRelative(:final path) => path,
    };
    return [
      '版本：${v.id}（${describeVersion(v)}）',
      '运行目录：${dir == state.paths.root ? '游戏文件夹根目录（未隔离）' : 'versions/${v.id}（已隔离）'}',
      'Java：${state.redactor().apply(java)}（这个版本需要 Java $required 或更高）',
      if (tooNew != null) '注意：$tooNew',
      '内存：${switch (s.memoryMode) {
        'custom' => '自定义',
        'auto' => '自动',
        _ => '跟随全局设置',
      }}',
      if (v.modable)
        '模组：${mods.where((m) => !m.disabled).length} 个启用，${mods.where((m) => m.disabled).length} 个禁用'
      else
        '这个版本没有模组加载器',
      '存档：${worlds.isEmpty ? '无' : worlds.join('、')}',
    ].join('\n');
  }

  Future<String> _listMods(InstanceInfo v) async {
    final mods =
        listInstanceFiles(
            await _gameDir(v),
            InstanceFolder.mods,
          ).where((f) => !f.isDir && (f.name.endsWith('.jar') || f.disabled)).toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (mods.isEmpty) return 'mods 文件夹中没有模组';
    return [for (final m in mods.take(400)) '- ${m.name}${m.disabled ? '（已禁用）' : ''}，${_size(m.size)}'].join('\n');
  }

  String _listDir(String root, String dir) {
    final entries = Directory(dir).listSync(followLinks: false)
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    if (entries.isEmpty) return '文件夹是空的';
    return [
      for (final e in entries.take(300))
        e is Link
            ? '- ${p.relative(e.path, from: root).replaceAll('\\', '/')}（符号链接，不能通过 AI 访问）'
            : e is Directory
            ? '- ${p.relative(e.path, from: root).replaceAll('\\', '/')}/'
            : '- ${p.relative(e.path, from: root).replaceAll('\\', '/')}（${_size(_sizeOf(e.path))}）',
      if (entries.length > 300) '……共 ${entries.length} 项，只列出前 300 项',
    ].join('\n');
  }

  Future<String> _readLog(InstanceInfo v, String kind) async {
    final dir = await _gameDir(v);
    File? f;
    // 日志会发给 AI，同样不能经过符号链接读到运行目录之外的文件
    if (kind == 'crash') {
      final d = Directory(p.join(dir, 'crash-reports'));
      final files = d.existsSync() && !isLink(d.path)
          ? d.listSync(followLinks: false).whereType<File>().where((f) => f.path.endsWith('.txt')).toList()
          : <File>[];
      files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      f = files.firstOrNull;
    } else {
      f = File(p.join(dir, 'logs', kind == 'debug' ? 'debug.log' : 'latest.log'));
    }
    if (f == null || !f.existsSync()) throw ToolError('没有找到${kind == 'crash' ? '崩溃报告' : '日志'}');
    _inside(dir, p.relative(f.path, from: dir));
    final bytes = await f.readAsBytes();
    final text = utf8.decode(
      bytes.length > 4 << 20 ? bytes.sublist(bytes.length - (4 << 20)) : bytes,
      allowMalformed: true,
    );
    return '${p.basename(f.path)}（修改于 ${f.statSync().modified.toString().substring(0, 19)}）\n'
        '${state.redactor().apply(excerptLog(text, budget: 16000))}';
  }

  Future<String> _search(InstanceInfo v, String q) async {
    final loaders = modrinthLoaders(v.loader);
    if (loaders.isEmpty) throw ToolError('${v.id} 不能安装模组（没有模组加载器）');
    final r = await Modrinth.search(
      type: ResourceType.mod,
      query: q,
      gameVersion: v.gameVersion,
      loader: loaders.first,
    );
    if (r.hits.isEmpty) return '没有找到与 ${v.gameVersion}（${loaders.first}）兼容的结果';
    return [
      for (final h in r.hits.take(10))
        '- ${h.title}（项目 ID：${h.id}，slug：${h.slug}，下载 ${h.downloads} 次）：${h.description.length > 120 ? '${h.description.substring(0, 120)}…' : h.description}',
    ].join('\n');
  }

  // ---------- 备份 ----------

  String _backupDir(InstanceInfo v) => p.join(state.paths.root, 'backups', v.id);

  /// 备份签名密钥，保存在启动器数据目录（AI 工具无法访问）
  static List<int> _backupKey() => backupKey(Paths.appData);

  /// 打包备份，返回备份文件路径
  Future<String> _backup(InstanceInfo v, String dir, List<String> paths, String label) async {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final safe = label.trim().replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    final base = '$stamp${safe.isEmpty ? '' : '-$safe'}';
    var out = p.join(_backupDir(v), '$base.zip');
    for (var i = 2; File(out).existsSync(); i++) {
      out = p.join(_backupDir(v), '$base-$i.zip');
    }
    await createBackup(out, dir, paths, versionId: v.id, key: _backupKey(), created: now);
    return out;
  }

  /// 恢复：先解压到临时文件夹并逐个校验，全部成功后才替换当前内容
  Future<String> _restore(InstanceInfo v, String dir, String zip, BackupCheck check) async {
    final staging = p.join(_backupDir(v), '.restore-${DateTime.now().millisecondsSinceEpoch}');
    try {
      await extractBackup(zip, staging, check);
    } catch (e) {
      await Directory(staging).delete(recursive: true).catchError((_) => Directory(staging));
      throw ToolError('备份解压或校验失败，没有做任何修改：$e');
    }
    // 用户确认后可能过了一段时间，替换前重新确认目标路径
    for (final rel in check.paths) {
      _inside(dir, rel);
    }
    final current = check.paths
        .where(
          (rel) => FileSystemEntity.typeSync(p.join(dir, rel), followLinks: false) != FileSystemEntityType.notFound,
        )
        .toList();
    String? before;
    if (current.isNotEmpty) before = await _backup(v, dir, current, 'before-restore');
    final done = <String>[];
    try {
      for (final rel in check.paths) {
        final target = _inside(dir, rel);
        if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
          await moveToTrash(target);
        }
        final from = p.joinAll([staging, ...rel.split('/')]);
        if (FileSystemEntity.typeSync(from, followLinks: false) != FileSystemEntityType.notFound) {
          await moveEntity(from, target);
        }
        done.add(rel);
      }
    } catch (e) {
      // 临时文件夹保留，里面是还没放回去的备份内容
      throw ToolError(
        '恢复到一半失败：$e。已恢复：${done.isEmpty ? '无' : done.join('、')}；'
        '${before == null ? '' : '恢复前的内容已备份到 ${p.basename(before)}，也可以在回收站找到；'}'
        '未完成的备份内容在 ${p.relative(staging, from: state.paths.root)}',
      );
    }
    await Directory(staging).delete(recursive: true).catchError((_) => Directory(staging));
    return '已恢复：${check.paths.join('、')}${before == null ? '' : '。恢复前的内容已备份到 ${p.basename(before)}'}';
  }

  Future<String> _listBackups(InstanceInfo v) async {
    final d = Directory(_backupDir(v));
    final zips = d.existsSync()
        ? (d.listSync(followLinks: false).whereType<File>().where((f) => f.path.endsWith('.zip')).toList())
        : <File>[];
    if (zips.isEmpty) return '${v.id} 还没有备份';
    zips.sort((a, b) => b.path.compareTo(a.path));
    return [
      for (final z in zips.take(50))
        '- ${p.basename(z.path)}（${_size(z.lengthSync())}）：${(await readBackupPaths(z.path))?.join('、') ?? '不是 Pixel World 创建的备份'}',
    ].join('\n');
  }
}

/// 记录 AI 执行过的修改操作，便于追查
Future<void> logAiOperation(String title, String result) async {
  try {
    final f = File(p.join(Paths.appData, 'ai_operations.log'));
    await f.writeAsString(
      '${jsonEncode({'time': DateTime.now().toIso8601String(), 'title': title, 'result': result})}\n',
      mode: FileMode.append,
    );
  } catch (_) {
    // 记录失败不影响操作
  }
}
