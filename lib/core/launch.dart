import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../app_info.dart';
import 'accounts.dart';
import 'cat_ini.dart';
import 'config.dart';
import 'instance_config.dart';
import 'mac_glfw.dart';
import 'java.dart';
import 'memory.dart';
import 'paths.dart';
import 'version.dart';

final _sep = Platform.isWindows ? ';' : ':';
bool _isAscii(String s) => s.codeUnits.every((c) => c < 0x80);

// ---------- natives ----------

/// 与 PCL-CE 相同的 natives 目录：`versions/<id>/<id>-natives`，路径含非 ASCII 字符时换到别处
String nativesDirFor(GamePaths g, String id) {
  final preferred = p.join(g.versionDir(id), '$id-natives');
  if (!Platform.isWindows || _isAscii(preferred)) return preferred;
  final fallback = p.join(Paths.officialMinecraftDir, 'bin', 'natives');
  if (_isAscii(fallback)) return fallback;
  return p.join(Platform.environment['ProgramData'] ?? r'C:\ProgramData', 'PCL.PW', 'natives');
}

Future<void> extractNatives(GamePaths g, VersionJson v, String dir) async {
  final d = Directory(dir);
  if (d.existsSync()) await d.delete(recursive: true);
  await d.create(recursive: true);
  for (final lib in resolveLibraries(g, v)) {
    if (!lib.native || !File(lib.path).existsSync()) continue;
    final zip = ZipDecoder().decodeBytes(await File(lib.path).readAsBytes());
    for (final e in zip.files) {
      if (!e.isFile) continue;
      if (lib.exclude.any(e.name.startsWith) || e.name.startsWith('META-INF/')) continue;
      // 只要动态库文件，扁平化放置
      if (!RegExp(r'\.(dll|so|dylib|jnilib)$', caseSensitive: false).hasMatch(e.name)) continue;
      await File(p.join(dir, e.name.split('/').last)).writeAsBytes(e.content);
    }
  }
}

// ---------- 参数 ----------

List<String> _expandArgs(List<dynamic> args, Map<String, bool> features) {
  final out = <String>[];
  for (final a in args) {
    if (a is String) {
      out.add(a);
    } else if (a is Map && rulesAllow(a['rules'] as List?, features)) {
      final value = a['value'];
      out.addAll(value is List ? value.map((x) => '$x') : ['$value']);
    }
  }
  return out;
}

/// 简单拆分命令行参数，支持引号
List<String> splitArgs(String s) =>
    RegExp(r'"[^"]*"|\S+').allMatches(s).map((m) => m.group(0)!.replaceAll(RegExp(r'^"|"$'), '')).toList();

/// 把 `-X` 与其后不以 `-` 开头的值合并后去重（PCL-CE 的做法，
/// 避免 Forge 1.17 的两个 --add-exports 被误去重）
List<String> _dedupeJvm(List<String> list) {
  final groups = <List<String>>[];
  for (var i = 0; i < list.length; i++) {
    final g = [list[i]];
    if (list[i].startsWith('-')) {
      while (i + 1 < list.length && !list[i + 1].startsWith('-')) {
        g.add(list[++i]);
      }
    }
    groups.add(g);
  }
  final seen = <String>{};
  return [
    for (final g in groups)
      if (g.join('\u0000') != '-XX:MaxDirectMemorySize=256M' && seen.add(g.join('\u0000'))) ...g,
  ];
}

class LaunchContext {
  LaunchContext({
    required this.g,
    required this.cfg,
    required this.v,
    required this.id,
    required this.acc,
    required this.java,
    required this.memory,
    required this.inst,
    required this.nativesDir,
    required this.gameDir,
    required this.windowSize,
    required this.demo,
    this.classpathHead = const [],
    this.classpathTail = const [],
    this.skipLibrary,
    this.authJvmArgs = const [],
  });

  /// 账户验证需要的 JVM 参数（外置登录的 authlib-injector）
  final List<String> authJvmArgs;

  /// 放在 classpath 最前面的 jar（安卓上替换游戏自带的 LWJGL）
  final List<String> classpathHead;

  /// 放在 classpath 最后的 jar（安卓上 LWJGL 2 版本的兼容层）
  final List<String> classpathTail;

  /// 不放进 classpath 的库（按库名判断）
  final bool Function(String name)? skipLibrary;

  final GamePaths g;
  final LauncherConfig cfg;
  final VersionJson v;
  final String id;
  final Account acc;
  final JavaInfo java;
  final MemoryPlan memory;
  final InstanceSettings inst;
  final String nativesDir;
  final String gameDir;
  final ({int width, int height}) windowSize;

  /// 试玩模式（正版购买劝导中选择「试玩」）
  final bool demo;
}

List<String> buildArgs(LaunchContext ctx) {
  final LaunchContext(:g, :cfg, :v, :acc, :java, :memory, :inst) = ctx;

  // classpath：OptiFine 放在倒数第二位，实例可指定 classpath 头部
  final libs = resolveLibraries(g, v).where((l) => l.classpath && !(ctx.skipLibrary?.call(l.name) ?? false)).toList();
  final optifine = libs.where((l) => RegExp(r'^optifine:optifine:', caseSensitive: false).hasMatch(l.name)).firstOrNull;
  final cp = <String>{
    for (final l in libs)
      if (l != optifine) l.path,
  }.toList();
  cp.add(g.versionJar(v.launchJar));
  if (optifine != null) cp.insert((cp.length - 2).clamp(0, cp.length), optifine.path);
  for (final head in inst.classpathHead.split(';').reversed) {
    if (head.trim().isNotEmpty) cp.insert(0, head.trim());
  }
  cp.insertAll(0, ctx.classpathHead);
  cp.addAll(ctx.classpathTail);

  final versionType = inst.versionType.isNotEmpty ? inst.versionType : cfg.versionType;
  final assetsId = '${v.assetIndex?['id'] ?? v.assets ?? 'legacy'}';
  final vars = <String, String>{
    'auth_player_name': acc.name,
    'version_name': ctx.id,
    'game_directory': ctx.gameDir,
    'assets_root': g.assets,
    'game_assets': p.join(g.assets, 'virtual', assetsId),
    'assets_index_name': assetsId,
    'auth_uuid': acc.uuid,
    'auth_access_token': acc.accessToken,
    'access_token': acc.accessToken,
    'auth_session': acc.accessToken,
    'auth_xuid': '0',
    'clientid': '0',
    // PCL-CE 对所有账户都使用 msa（PCL #1221）
    'user_type': 'msa',
    'user_properties': '{}',
    'version_type': versionType,
    'natives_directory': ctx.nativesDir,
    'launcher_name': AppInfo.name,
    'launcher_version': AppInfo.version,
    'classpath': cp.join(_sep),
    'classpath_separator': _sep,
    'library_directory': g.libraries,
    'libraries_directory': g.libraries,
    'resolution_width': '${ctx.windowSize.width}',
    'resolution_height': '${ctx.windowSize.height}',
  };
  String fill(String s) => s.replaceAllMapped(RegExp(r'\$\{(\w+)\}'), (m) => vars[m.group(1)] ?? m.group(0)!);
  final fullscreen = cfg.windowMode == 'fullscreen';
  final features = {'has_custom_resolution': !fullscreen, 'is_demo_user': ctx.demo};

  // ---- JVM ----
  final jvm = splitArgs(inst.jvmArgs.isNotEmpty ? inst.jvmArgs : cfg.jvmArgs);
  if (v.jvmArguments != null) {
    jvm.addAll(_expandArgs(v.jvmArguments!, features));
  } else {
    // LWJGL 3 在 macOS 上必须在主线程运行；LWJGL 2（1.12.2 及更早）通过 AWT 创建窗口，加上这个参数窗口不会显示
    if (Platform.isMacOS && v.libraries.any((l) => '${l['name']}'.startsWith('org.lwjgl:lwjgl:3.'))) {
      jvm.add('-XstartOnFirstThread');
    }
    jvm.addAll([r'-Djava.library.path=${natives_directory}', '-cp', r'${classpath}']);
  }
  // Apple 芯片的 Mac 上 1.13～1.18：使用去掉了窗口图标报错的 GLFW（mac_glfw.dart）
  if (needsAppleSiliconGlfw(v.libraries)) jvm.add('-Dorg.lwjgl.glfw.libname=$appleSiliconGlfwPath');
  if (cfg.preferredIpStack == 'v4') {
    jvm.addAll(['-Djava.net.preferIPv4Stack=true', '-Djava.net.preferIPv4Addresses=true']);
  }
  if (cfg.preferredIpStack == 'v6') {
    jvm.addAll(['-Djava.net.preferIPv6Stack=true', '-Djava.net.preferIPv6Addresses=true']);
  }

  final maxMb = (memory.max * 1024).floor();
  jvm.addAll(['-Xmn${(maxMb * 0.15).floor()}m', '-Xmx${maxMb}m']);
  if (memory.initial != null && !jvm.any((a) => a.toLowerCase().contains('-xms'))) {
    jvm.add('-Xms${(memory.initial! * 1024).floor()}m');
  }
  if (!jvm.contains('-Dlog4j2.formatMsgNoLookups=true')) jvm.add('-Dlog4j2.formatMsgNoLookups=true');
  jvm.addAll(ctx.authJvmArgs);

  // 编码（PCL #4700、#5892、#5909）
  if (java.major > 8) {
    if (!jvm.any((a) => a.startsWith('-Dstdout.encoding='))) jvm.insert(0, '-Dstdout.encoding=UTF-8');
    if (!jvm.any((a) => a.startsWith('-Dstderr.encoding='))) jvm.insert(0, '-Dstderr.encoding=UTF-8');
  } else {
    jvm.insertAll(0, ['-Dsun.stdout.encoding=UTF-8', '-Dsun.stderr.encoding=UTF-8']);
  }
  if (java.major >= 18 && !jvm.any((a) => a.startsWith('-Dfile.encoding='))) jvm.insert(0, '-Dfile.encoding=COMPAT');

  // 旧版本的 Log4Shell 修复配置
  final logging = v.loggingClient;
  if (logging != null) {
    jvm.add(
      '${logging['argument']}'.replaceAll(
        r'${path}',
        p.join(g.assets, 'log_configs', '${(logging['file'] as Map)['id']}'),
      ),
    );
  }

  // ---- Game ----
  var game = v.gameArguments != null ? _expandArgs(v.gameArguments!, features) : splitArgs(v.minecraftArguments ?? '');
  if (v.gameArguments == null && !fullscreen) {
    game.addAll(['--width', r'${resolution_width}', '--height', r'${resolution_height}']);
  }
  if (fullscreen) game.add('--fullscreen');
  // 1.13 之后的版本由 is_demo_user 特性加上 --demo，旧版本手动添加
  if (ctx.demo && !game.contains('--demo')) game.add('--demo');
  game.addAll(splitArgs(inst.gameArgs.isNotEmpty ? inst.gameArgs : cfg.gameArgs));
  // 版本类型为空时去掉 --versionType
  if (versionType.isEmpty) {
    final i = game.indexOf('--versionType');
    if (i >= 0) game = [...game.sublist(0, i), ...game.sublist((i + 2).clamp(0, game.length))];
  }

  // 自动进入服务器：2023-04-04 之后的版本用 QuickPlay
  final server = inst.server.trim();
  if (server.isNotEmpty) {
    final t = DateTime.tryParse(v.releaseTime ?? '');
    if (t != null && t.isAfter(DateTime.utc(2023, 4, 4))) {
      game.addAll(['--quickPlayMultiplayer', server]);
    } else {
      final parts = server.split(':');
      game.addAll(['--server', parts[0], '--port', parts.length > 1 ? parts[1] : '25565']);
    }
  }

  return [..._dedupeJvm(jvm), v.mainClass, ...game].map(fill).toList();
}

// ---------- 启动前处理 ----------

/// options.txt：按 PCL-CE 的规则设置语言与全屏
Future<void> prepareOptions(LauncherConfig cfg, String gameDir, String? releaseTime) async {
  var file = p.join(gameDir, 'options.txt');
  // Yosbr 兼容
  final yosbr = p.join(gameDir, 'config', 'yosbr', 'options.txt');
  if (!File(file).existsSync() && File(yosbr).existsSync()) file = yosbr;

  if (cfg.autoGameLanguage) {
    final time = releaseTime == null ? null : DateTime.tryParse(releaseTime);
    final current = readCatIni(file)['lang'] ?? 'none';
    final useLauncher = current.toLowerCase() == 'none' || !Directory(p.join(gameDir, 'saves')).existsSync();
    final locale = Platform.localeName.split('.').first;
    var lang = 'none';
    // 1.1 之前没有语言选项；1.1~1.10 需要大写地区（zh_CN），之后为小写
    if (!(time != null && time.isAfter(DateTime(2000)) && !time.isAfter(DateTime(2011, 11, 18)))) {
      final legacy = time != null && !time.isBefore(DateTime(2012, 1, 12)) && !time.isAfter(DateTime(2016, 6, 8));
      final code = (useLauncher ? locale : current).replaceAll('-', '_');
      final parts = code.split('_');
      lang = parts.length > 1
          ? '${parts[0].toLowerCase()}_${legacy ? parts[1].toUpperCase() : parts[1].toLowerCase()}'
          : code.toLowerCase();
    }
    if (current != lang) {
      await writeCatIni(file, 'lang', '-');
      await writeCatIni(file, 'lang', lang);
    }
    if (useLauncher && RegExp('^(zh|ja|ko)', caseSensitive: false).hasMatch(locale)) {
      await writeCatIni(file, 'forceUnicodeFont', 'true');
    }
  }

  if (cfg.windowMode == 'fullscreen') {
    await writeCatIni(file, 'fullscreen', 'true');
  } else if (cfg.windowMode != 'default') {
    await writeCatIni(file, 'fullscreen', 'false');
  }
}

/// 安卓：关闭 Forge 1.7~1.12 的加载画面。加载画面在另一个线程里占用 GL 上下文，安卓上不能共享上下文，
/// 主线程拼贴图时查不到最大贴图尺寸，报 StitcherException（atlasMax: -1x-1）。其他版本不读这个文件
Future<void> disableForgeSplash(String gameDir) async {
  final f = File(p.join(gameDir, 'config', 'splash.properties'));
  if (!f.existsSync()) {
    await f.parent.create(recursive: true);
    await f.writeAsString('enabled=false\n');
    return;
  }
  final text = await f.readAsString();
  final enabled = RegExp(r'^enabled=.*$', multiLine: true);
  final String fixed;
  if (enabled.hasMatch(text)) {
    fixed = text.replaceAll(enabled, 'enabled=false');
  } else {
    fixed = '${text.isEmpty || text.endsWith('\n') ? text : '$text\n'}enabled=false\n';
  }
  if (fixed != text) await f.writeAsString(fixed);
}

/// Windows：让 Java 使用高性能显卡（写入当前用户的图形偏好）
Future<void> setGpuPreference(String javaPath) async {
  if (!Platform.isWindows) return;
  await Process.run('reg', [
    'add',
    r'HKCU\Software\Microsoft\DirectX\UserGpuPreferences',
    '/v',
    javaPath,
    '/t',
    'REG_SZ',
    '/d',
    'GpuPreference=2;',
    '/f',
  ]).catchError((_) => ProcessResult(0, 1, '', ''));
}

/// 启动前自定义命令，在游戏文件夹中执行
Future<void> runPreLaunch(String command, bool wait, String cwd, void Function(String) log) async {
  if (command.trim().isEmpty) return;
  log('执行启动前命令：$command');
  final proc = await Process.start(
    Platform.isWindows ? 'cmd.exe' : '/bin/sh',
    Platform.isWindows ? ['/c', command] : ['-c', command],
    workingDirectory: cwd,
    mode: wait ? ProcessStartMode.normal : ProcessStartMode.detached,
  );
  if (wait) {
    unawaited(proc.stdout.drain<void>());
    unawaited(proc.stderr.drain<void>());
    await proc.exitCode;
  }
}

/// 写出最近一次的启动脚本（令牌已隐藏），对应 PCL 的 LatestLaunch.bat
Future<void> writeLaunchScript(String java, List<String> args, String gameDir, Account acc, String title) async {
  String quote(String a) => RegExp(r'[\s"&|<>^]').hasMatch(a) ? '"${a.replaceAll('"', r'\"')}"' : a;
  final masked = args.map((a) => acc.accessToken.isNotEmpty && a == acc.accessToken ? '<access_token>' : a);
  final cmd = '${quote(java)} ${masked.map(quote).join(' ')}';
  final script = Platform.isWindows
      ? ['chcp 65001>nul', '@echo off', 'title $title', 'cd /D ${quote(gameDir)}', cmd, 'pause'].join('\r\n')
      : ['#!/bin/sh', 'cd ${quote(gameDir)}', cmd].join('\n');
  await File(p.join(Paths.appData, Platform.isWindows ? 'LatestLaunch.bat' : 'LatestLaunch.sh'))
      .writeAsString(script)
      .catchError((_) => File(''));
}

/// 设置游戏进程优先级（Windows）
Future<void> setPriority(int pid, String priority) async {
  if (!Platform.isWindows || priority == 'normal') return;
  const names = {'realtime': 'RealTime', 'high': 'High', 'aboveNormal': 'AboveNormal', 'belowNormal': 'BelowNormal'};
  final name = names[priority];
  if (name == null) return;
  await Process.run('powershell.exe', [
    '-NoProfile',
    '-Command',
    '(Get-Process -Id $pid).PriorityClass = "$name"',
  ]).catchError((_) => ProcessResult(0, 1, '', ''));
}

// ---------- 日志处理：把 log4j XML 事件转为可读文本 ----------

class LogParser {
  LogParser(this.emit);

  final void Function(List<String> lines) emit;
  var _buf = '';

  static String _attr(String ev, String n) => RegExp('$n="([^"]*)"').firstMatch(ev)?.group(1) ?? '';

  void push(String chunk) {
    _buf += chunk;
    final lines = <String>[];
    List<String> split(String s) => s.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).toList();
    while (true) {
      final start = _buf.indexOf('<log4j:Event');
      if (start == -1) {
        final nl = _buf.lastIndexOf('\n');
        if (nl == -1) break;
        lines.addAll(split(_buf.substring(0, nl)));
        _buf = _buf.substring(nl + 1);
        break;
      }
      if (start > 0) {
        lines.addAll(split(_buf.substring(0, start)));
        _buf = _buf.substring(start);
        continue;
      }
      final end = _buf.indexOf('</log4j:Event>');
      if (end == -1) break;
      final ev = _buf.substring(0, end);
      _buf = _buf.substring(end + '</log4j:Event>'.length);
      final msg = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>').firstMatch(ev)?.group(1) ?? '';
      final ts = int.tryParse(_attr(ev, 'timestamp'));
      final time = ts == null ? '' : DateTime.fromMillisecondsSinceEpoch(ts).toIso8601String().substring(11, 19);
      lines.add('[$time] [${_attr(ev, 'thread')}/${_attr(ev, 'level')}]: $msg');
      final thrown = RegExp(r'<log4j:Throwable><!\[CDATA\[([\s\S]*?)\]\]>').firstMatch(ev)?.group(1);
      if (thrown != null) lines.addAll(thrown.split(RegExp(r'\r?\n')));
    }
    if (lines.isNotEmpty) emit(lines);
  }
}

/// 启动游戏进程，返回 Process（启动后直接退出时为 detached）
Future<Process> startGame(LaunchContext ctx, List<String> args, {required bool detached}) {
  final env = Map<String, String>.from(Platform.environment);
  final pathKey = env.keys.firstWhere((k) => k.toUpperCase() == 'PATH', orElse: () => 'PATH');
  env[pathKey] = {...(env[pathKey] ?? '').split(_sep), p.dirname(ctx.java.path)}.join(_sep);
  // PCL-CE 把 APPDATA 指向游戏文件夹，部分老 Mod 依赖此行为
  if (Platform.isWindows) env['APPDATA'] = ctx.g.root;
  return Process.start(
    ctx.java.path,
    args,
    workingDirectory: ctx.gameDir,
    environment: env,
    includeParentEnvironment: false,
    mode: detached ? ProcessStartMode.detached : ProcessStartMode.normal,
  );
}

/// 解码游戏输出：Java 9+ 已通过参数指定 UTF-8
Stream<String> decodeOutput(Stream<List<int>> s) => s.transform(const Utf8Decoder(allowMalformed: true));
