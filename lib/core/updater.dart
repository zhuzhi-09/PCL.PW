import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../app_info.dart';
import '../installer/installer_core.dart' show appExeNames;
import 'site_api.dart';

/// 启动器的更新通道，对应 GitHub Releases 中的三类发布（见 .github/workflows/release.yml）
enum UpdateChannel {
  /// 不带「-」的 v* 标签
  stable('正式版'),

  /// 所有 v* 标签，包括 v0.4.0-beta 这样的预发布
  preview('预览版'),

  /// main 分支的每次更新，标签固定为 nightly
  nightly('Nightly');

  const UpdateChannel(this.label);

  final String label;

  static UpdateChannel parse(String s) =>
      values.where((c) => c.name == s).firstOrNull ??
      values.where((c) => c.name == AppInfo.channel).firstOrNull ??
      stable;
}

class ReleaseAsset {
  ReleaseAsset({required this.name, required this.url, required this.size, this.sha256});

  final String name;
  final String url;
  final int size;

  /// GitHub 为发布文件计算的 SHA-256（较早上传的文件没有）
  final String? sha256;
}

class Release {
  Release({
    required this.tag,
    required this.name,
    required this.body,
    required this.prerelease,
    required this.commit,
    required this.publishedAt,
    required this.assets,
    required this.page,
  });

  factory Release.fromJson(Map<String, dynamic> j) => Release(
    tag: '${j['tag_name'] ?? ''}',
    name: '${j['name'] ?? j['tag_name'] ?? ''}',
    body: '${j['body'] ?? ''}',
    prerelease: j['prerelease'] == true,
    commit: '${j['target_commitish'] ?? ''}',
    publishedAt: DateTime.tryParse('${j['published_at'] ?? ''}'),
    page: '${j['html_url'] ?? ''}',
    assets: [
      for (final a in (j['assets'] as List? ?? const []).whereType<Map<String, dynamic>>())
        ReleaseAsset(
          name: '${a['name']}',
          url: '${a['browser_download_url']}',
          size: (a['size'] as num?)?.toInt() ?? 0,
          sha256: RegExp(r'^sha256:([0-9a-f]{64})$').firstMatch('${a['digest'] ?? ''}')?.group(1),
        ),
    ],
  );

  /// 自有静态接口中的发布条目（见 update.json 的 channels）
  factory Release.fromSite(Map<String, dynamic> j) => Release(
    tag: '${j['tag'] ?? ''}',
    name: '${j['name'] ?? j['tag'] ?? ''}',
    body: '${j['body'] ?? ''}',
    prerelease: j['prerelease'] == true,
    commit: '${j['commit'] ?? ''}',
    publishedAt: DateTime.tryParse('${j['publishedAt'] ?? ''}'),
    page: '${j['page'] ?? ''}',
    assets: [
      for (final a in (j['assets'] as List? ?? const []).whereType<Map<String, dynamic>>())
        ReleaseAsset(
          name: '${a['name'] ?? ''}',
          url: '${a['url'] ?? ''}',
          size: (a['size'] as num?)?.toInt() ?? 0,
          sha256: RegExp(r'^[0-9a-fA-F]{64}$').hasMatch('${a['sha256']}') ? '${a['sha256']}'.toLowerCase() : null,
        ),
    ],
  );

  final String tag;
  final String name;
  final String body;
  final bool prerelease;

  /// nightly 发布指向的提交（工作流用 --target 指定为完整的提交号）
  final String commit;
  final DateTime? publishedAt;
  final List<ReleaseAsset> assets;
  final String page;

  bool get isNightly => tag == 'nightly';

  /// v0.3.0 → 0.3.0
  String get version => tag.startsWith('v') ? tag.substring(1) : tag;

  /// 显示用的版本名与用于「跳过这个版本」的键
  String get label => isNightly ? 'Nightly ${commit.length >= 7 ? commit.substring(0, 7) : commit}' : tag;
  String get key => isNightly ? 'nightly-$commit' : tag;
}

/// 比较版本号：1.2.3 > 1.2.3-beta.2 > 1.2.3-beta.1 > 1.2.2；返回正数表示 [a] 更新
int compareVersions(String a, String b) {
  (List<int>, String?) split(String v) {
    v = v.trim().replaceFirst(RegExp(r'^v'), '').split('+').first;
    final dash = v.indexOf('-');
    final core = dash < 0 ? v : v.substring(0, dash);
    return ([for (final x in core.split('.')) int.tryParse(x) ?? 0], dash < 0 ? null : v.substring(dash + 1));
  }

  final (ca, pa) = split(a);
  final (cb, pb) = split(b);
  for (var i = 0; i < 3 || i < ca.length || i < cb.length; i++) {
    final x = i < ca.length ? ca[i] : 0, y = i < cb.length ? cb[i] : 0;
    if (x != y) return x - y;
  }
  if (pa == pb) return 0;
  // 没有预发布后缀的更新
  if (pa == null) return 1;
  if (pb == null) return -1;
  final xa = pa.split('.'), xb = pb.split('.');
  for (var i = 0; i < xa.length && i < xb.length; i++) {
    final na = int.tryParse(xa[i]), nb = int.tryParse(xb[i]);
    final c = na != null && nb != null ? na - nb : xa[i].compareTo(xb[i]);
    if (c != 0) return c;
  }
  return xa.length - xb.length;
}

final _versionTag = RegExp(r'^v\d+(\.\d+)*(-[0-9A-Za-z.-]+)?$');

/// 通道中最新的发布
Release? latestRelease(List<Release> list, UpdateChannel channel) {
  if (channel == UpdateChannel.nightly) return list.where((r) => r.isNightly).firstOrNull;
  final candidates = list
      .where((r) => _versionTag.hasMatch(r.tag) && (channel == UpdateChannel.preview || !r.prerelease))
      .toList();
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) => compareVersions(b.version, a.version));
  return candidates.first;
}

/// [r] 是否比当前构建新。nightly 按提交号判断：本地构建没有提交号，视为需要更新
bool isNewer(Release r, {String currentVersion = AppInfo.version, String currentCommit = AppInfo.commit}) {
  if (r.isNightly) {
    if (currentCommit.isEmpty || r.commit.isEmpty) return true;
    return !r.commit.startsWith(currentCommit) && !currentCommit.startsWith(r.commit);
  }
  return compareVersions(r.version, currentVersion) > 0;
}

/// Windows 上通过安装程序安装（安装目录中有安装清单），否则为便携版
bool get isInstalledWindowsBuild =>
    Platform.isWindows && File(p.join(p.dirname(Platform.resolvedExecutable), '.pw-install.json')).existsSync();

/// 当前平台使用的发布文件；Linux 还没有发布包
/// 当前程序的 Windows 架构：ARM64 版选 arm64 的安装包；x64 版（包括在 ARM 电脑上模拟运行的）选 x64
String get windowsArch => Abi.current() == Abi.windowsArm64 ? 'arm64' : 'x64';

ReleaseAsset? assetFor(Release r, {bool? android, bool? windows, bool? macos, bool? installed, String? arch}) {
  android ??= Platform.isAndroid;
  windows ??= Platform.isWindows;
  macos ??= Platform.isMacOS;
  installed ??= isInstalledWindowsBuild;
  final String suffix;
  if (android) {
    suffix = '-android-arm64.apk';
  } else if (windows) {
    final a = arch ?? windowsArch;
    suffix = installed ? '-windows-$a-setup.exe' : '-windows-$a-portable.zip';
  } else if (macos) {
    suffix = '-macos.dmg';
  } else {
    return null;
  }
  return r.assets.where((a) => a.name.endsWith(suffix)).firstOrNull;
}

final _client = HttpClient()
  ..userAgent = '${AppInfo.name}/${AppInfo.version}'
  ..connectionTimeout = const Duration(seconds: 20);

Future<List<Release>> fetchReleases() async {
  final req = await _client.getUrl(Uri.parse('${AppInfo.repoApi}/releases?per_page=30'));
  req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
  final res = await req.close().timeout(const Duration(seconds: 30));
  final body = await res.transform(utf8.decoder).join();
  if (res.statusCode == 403 || res.statusCode == 429) throw Exception('GitHub 访问次数超出限制，请稍后再试');
  if (res.statusCode != 200) throw Exception('无法获取更新信息（HTTP ${res.statusCode}）');
  return [for (final j in (jsonDecode(body) as List).whereType<Map<String, dynamic>>()) Release.fromJson(j)];
}

/// 检查更新：优先使用自有静态接口，接口不可用或内容无效时回落到 GitHub API；
/// 返回比当前构建新的发布，没有时返回 null
Future<Release?> checkForUpdate(UpdateChannel channel) async {
  final site = await fetchUpdateChannels();
  final Release? r = site != null ? site[channel.name] : latestRelease(await fetchReleases(), channel);
  return r != null && isNewer(r) ? r : null;
}

/// 安卓上没有「安装未知应用」权限。安装包已经下载好，授权后可以继续安装，不需要重新下载
class InstallPermissionException implements Exception {
  @override
  String toString() => '需要允许安装未知应用';
}

/// 下载发布文件到临时文件夹，核对大小与 SHA-256。
/// 如果之前已经下载过同一个文件（例如授权后重试），核对通过就直接复用。
Future<File> downloadAsset(
  ReleaseAsset asset, {
  void Function(int received, int total)? onProgress,
  Directory? directory,
}) async {
  final dir = directory ?? Directory(p.join(Directory.systemTemp.path, 'pclpw-update'));
  await dir.create(recursive: true);
  final out = File(p.join(dir.path, asset.name));
  if (await _matchesAsset(out, asset)) {
    onProgress?.call(asset.size, asset.size);
    await _removeOtherDownloads(dir, asset.name);
    return out;
  }
  // 上次中断留下的同一文件先删掉
  if (out.existsSync()) await out.delete();
  final tmp = File('${out.path}.part');
  final req = await _client.getUrl(Uri.parse(asset.url));
  final res = await req.close().timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) {
    await res.drain<void>();
    throw Exception('下载失败（HTTP ${res.statusCode}）');
  }
  final total = asset.size > 0 ? asset.size : res.contentLength;
  final sink = tmp.openWrite();
  var received = 0;
  final digest = _DigestSink();
  final hasher = sha256.startChunkedConversion(digest);
  try {
    await for (final chunk in res.timeout(const Duration(seconds: 60))) {
      sink.add(chunk);
      hasher.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
  } finally {
    await sink.close();
    hasher.close();
  }
  if (asset.size > 0 && received != asset.size) {
    await tmp.delete();
    throw Exception('下载不完整（$received / ${asset.size} 字节）');
  }
  if (asset.sha256 != null && digest.value.toString() != asset.sha256) {
    await tmp.delete();
    throw Exception('文件校验失败（SHA-256 不匹配）');
  }
  if (out.existsSync()) await out.delete();
  final file = await tmp.rename(out.path);
  await _removeOtherDownloads(dir, asset.name);
  return file;
}

/// 本地已有的文件是否与发布文件一致：大小相同，并且（有 SHA-256 时）摘要相同
Future<bool> _matchesAsset(File file, ReleaseAsset asset) async {
  if (!file.existsSync()) return false;
  if (asset.size > 0 && await file.length() != asset.size) return false;
  final want = asset.sha256;
  if (want == null || want.isEmpty) return true;
  try {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == want;
  } catch (_) {
    return false;
  }
}

/// 只保留本次要安装的文件；同一个更新目录里其他版本的安装包和残留分片都删掉
Future<void> _removeOtherDownloads(Directory dir, String keep) async {
  try {
    await for (final e in dir.list()) {
      if (e is File && p.basename(e.path) != keep) {
        await e.delete().catchError((_) => e);
      }
    }
  } catch (_) {
    // 清理失败不影响更新
  }
}

const _channel = MethodChannel('pclpw/update');

/// 安装下载好的更新。Windows 上会启动安装程序或替换脚本，然后由调用方退出启动器
Future<void> applyUpdate(File file) async {
  if (Platform.isAndroid) {
    // 系统会弹出安装确认；首次需要允许「安装未知应用」
    try {
      await _channel.invokeMethod('installApk', {'path': file.path});
    } on PlatformException catch (e) {
      if (e.code == 'permission') throw InstallPermissionException();
      throw Exception(e.message ?? e.code);
    }
    return;
  }
  // macOS：打开下载的 dmg，由用户把新版本拖进「应用程序」替换旧版本
  if (Platform.isMacOS) {
    await Process.run('open', [file.path]);
    return;
  }
  if (!Platform.isWindows) throw UnsupportedError('这个平台暂不支持自动更新');
  if (file.path.endsWith('.exe')) {
    await Process.start(file.path, const [], mode: ProcessStartMode.detached);
    return;
  }
  // 便携版：解压后等启动器退出，再覆盖程序文件夹并重新启动（用户数据在 %APPDATA%，不受影响）
  final stage = Directory(p.join(p.dirname(file.path), 'portable'));
  if (stage.existsSync()) await stage.delete(recursive: true);
  await extractFileToDisk(file.path, stage.path);
  final top = stage.listSync().whereType<Directory>().toList();
  final source = top.length == 1 && stage.listSync().length == 1 ? top.single.path : stage.path;
  final target = p.dirname(Platform.resolvedExecutable);
  final script = portableUpdateScript(source: source, target: target, pid: pid).join('; ');
  await Process.start('powershell.exe', [
    '-NoProfile',
    '-WindowStyle',
    'Hidden',
    '-Command',
    script,
  ], mode: ProcessStartMode.detached);
}

/// 便携版替换脚本（PowerShell）的各条命令。主程序可能叫 Pixel World.exe 或 PCL.PW.exe（见 [appExeNames]），
/// 以更新包里的为准；名字变了时删掉旧名字的程序，免得留下一个过期的 exe
@visibleForTesting
List<String> portableUpdateScript({required String source, required String target, required int pid}) {
  String q(String s) => "'${s.replaceAll("'", "''")}'";
  final name = appExeNames.where((n) => File(p.join(source, n)).existsSync()).firstOrNull;
  if (name == null) throw Exception('更新包中找不到主程序（${appExeNames.join(' 或 ')}）');
  return [
    'Wait-Process -Id $pid -ErrorAction SilentlyContinue',
    'Start-Sleep -Milliseconds 500',
    'robocopy ${q(source)} ${q(target)} /E /R:5 /W:1 /NFL /NDL /NJH /NJS | Out-Null',
    for (final old in appExeNames)
      if (old != name) 'Remove-Item -LiteralPath ${q(p.join(target, old))} -Force -ErrorAction SilentlyContinue',
    'Start-Process ${q(p.join(target, name))}',
  ];
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
