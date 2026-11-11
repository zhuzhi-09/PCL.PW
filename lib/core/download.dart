import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../app_info.dart';

const _bmclapi = 'https://bmclapi2.bangbang93.com';

const _mirrors = [
  ('https://piston-meta.mojang.com', _bmclapi),
  ('https://launchermeta.mojang.com', _bmclapi),
  ('https://piston-data.mojang.com', _bmclapi),
  ('https://launcher.mojang.com', _bmclapi),
  ('https://resources.download.minecraft.net', '$_bmclapi/assets'),
  ('https://libraries.minecraft.net', '$_bmclapi/maven'),
  ('https://maven.fabricmc.net', '$_bmclapi/maven'),
  ('https://meta.fabricmc.net', '$_bmclapi/fabric-meta'),
  ('https://maven.minecraftforge.net', '$_bmclapi/maven'),
  ('https://maven.neoforged.net/releases', '$_bmclapi/maven'),
  ('https://authlib-injector.yushi.moe', '$_bmclapi/mirrors/authlib-injector'),
];

/// GitHub 直连失败或卡住时依次尝试的镜像
const _githubProxies = ['https://ghproxy.net/', 'https://gh-proxy.com/', 'https://ghfast.top/'];

bool _isGitHubUrl(String url) =>
    url.startsWith('https://github.com/') || url.startsWith('https://raw.githubusercontent.com/');

/// [url] 的 GitHub 镜像地址；不是 GitHub 地址时返回空列表
List<String> githubMirrorsFor(String url) =>
    _isGitHubUrl(url) ? [for (final proxy in _githubProxies) '$proxy$url'] : const <String>[];

class DownloadItem {
  DownloadItem({required this.url, required this.path, this.sha1, this.size});

  final String url;
  final String path;
  final String? sha1;
  final int? size;
}

/// 下载器。下载源（官方 / BMCLAPI）与并发数来自设置。
class Downloader {
  Downloader({required this.useMirror, required this.concurrency});

  final bool useMirror;
  final int concurrency;

  static final _client = HttpClient()
    ..userAgent = '${AppInfo.name}/${AppInfo.version}'
    ..connectionTimeout = const Duration(seconds: 20);

  /// 根据下载源设置把官方地址替换为镜像地址
  String mirror(String url) {
    if (!useMirror) return url;
    for (final (from, to) in _mirrors) {
      if (url.startsWith(from)) return to + url.substring(from.length);
    }
    return url;
  }

  /// 低于这个速度视为分到了慢节点（字节/秒），断开重连
  static const _slowSpeed = 64 * 1024;
  static const _chunkThreshold = 8 * 1024 * 1024;
  static const _chunkCount = 4;

  Future<List<int>> _get(String url, {int retries = 3, bool Function()? cancelled, String? range}) async {
    // 镜像失败时回退到官方源；GitHub 地址再依次尝试 ghproxy 等镜像
    final candidates = <String>{mirror(url), if (mirror(url) != url) url, ...githubMirrorsFor(url)}.toList();
    Object? lastErr;
    for (final target in candidates) {
      // BMCLAPI 会重定向到随机的社区节点，个别节点的证书链不完整（不发送中间证书），
      // 系统浏览器能自动补全而 Dart 不能；重新请求会分到另一个节点，所以握手失败时多试几次
      var handshakeRetries = 6;
      for (var i = 0; i < retries; i++) {
        // 最后一次尝试不再按速度断开，避免网络本身慢时永远下不完
        final checkSpeed = i < retries - 1;
        try {
          final req = await _client.getUrl(Uri.parse(target));
          if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
          final res = await req.close().timeout(const Duration(seconds: 30));
          final ok = range == null ? res.statusCode == 200 : res.statusCode == 206;
          if (ok) {
            final b = BytesBuilder(copy: false);
            final sw = Stopwatch()..start();
            await for (final chunk in res.timeout(const Duration(seconds: 20))) {
              if (cancelled?.call() ?? false) throw const _Cancelled();
              b.add(chunk);
              final secs = sw.elapsedMilliseconds / 1000;
              if (checkSpeed && secs > 8 && b.length / secs < _slowSpeed) {
                throw HttpException('下载速度过慢，更换节点重试：$target');
              }
            }
            return b.takeBytes();
          }
          await res.drain<void>();
          if (range != null && res.statusCode == 200) throw const _RangeUnsupported();
          lastErr = HttpException('HTTP ${res.statusCode} $target');
          if (res.statusCode == 404) break;
        } on _Cancelled {
          rethrow;
        } on _RangeUnsupported {
          rethrow;
        } on HandshakeException catch (e) {
          lastErr = e;
          if (handshakeRetries-- > 0) {
            i--;
            continue;
          }
        } catch (e) {
          lastErr = e;
        }
        await Future<void>.delayed(Duration(milliseconds: 500 * (i + 1)));
      }
    }
    throw lastErr ?? Exception('下载失败：$url');
  }

  Future<dynamic> fetchJson(String url) async => jsonDecode(utf8.decode(await _get(url)));

  Future<String> fetchText(String url) async => utf8.decode(await _get(url));

  /// 判断本地文件是否完整：
  ///  - 有 SHA-1 时按 SHA-1 校验；校验通过的文件记下大小与修改时间，之后未变化就不再重复计算；
  ///  - 只有大小时按大小判断（只能发现截断，发现不了同样大小的损坏）；
  ///  - 两者都没有时只要求文件非空。
  static Future<bool> isComplete(DownloadItem item) async {
    final f = File(item.path);
    final FileStat stat;
    try {
      stat = await f.stat();
    } on FileSystemException {
      return false;
    }
    if (stat.type != FileSystemEntityType.file) return false;
    if (item.size != null ? stat.size != item.size : stat.size == 0) return false;
    final want = item.sha1?.toLowerCase();
    if (want == null || want.isEmpty) return true;
    if (VerifiedFiles.matches(item.path, stat, want)) return true;
    final String actual;
    try {
      actual = (await sha1.bind(f.openRead()).first).toString();
    } on FileSystemException {
      return false;
    }
    if (actual != want) return false;
    VerifiedFiles.record(item.path, stat, want);
    return true;
  }

  static var _tmpSeq = 0;

  /// 下载到临时文件，校验通过后再替换正式文件，中断或校验失败都不会留下看似完整的文件。
  /// [cancelled] 返回 true 时放弃下载（同一文件的另一个连接已经完成）
  Future<void> downloadFile(DownloadItem item, {bool Function()? cancelled}) async {
    final size = item.size;
    // 大文件拆成多个 Range 连接并行下载；服务器不支持 Range 时回退到单连接
    if (size != null && size >= _chunkThreshold) {
      try {
        await _downloadChunked(item, size, cancelled);
        return;
      } on _RangeUnsupported {
        // 回退
      } catch (e) {
        if (cancelled?.call() ?? false) rethrow;
        // 分块失败时再用普通下载重试一次
      }
    }
    final data = await _get(item.url, cancelled: cancelled);
    final want = item.sha1?.toLowerCase();
    if (want != null && want.isNotEmpty && sha1.convert(data).toString() != want) {
      throw Exception('校验失败（SHA-1 不匹配）：${item.path}');
    }
    if (item.size != null && data.length != item.size) {
      throw Exception('校验失败（大小应为 ${item.size}，实际 ${data.length}）：${item.path}');
    }
    if (cancelled?.call() ?? false) return;
    final f = File(item.path);
    await f.parent.create(recursive: true);
    // 同一文件可能有两个连接同时下载，临时文件名要区分
    final tmp = File('${item.path}.$pid.${_tmpSeq++}.tmp');
    try {
      await tmp.writeAsBytes(data, flush: true);
      await tmp.rename(item.path);
    } catch (_) {
      await tmp.delete().catchError((_) => tmp);
      rethrow;
    }
    if (want != null && want.isNotEmpty) {
      try {
        VerifiedFiles.record(item.path, await f.stat(), want);
      } on FileSystemException {
        // 记录失败只会导致下次重新校验
      }
    }
  }

  /// 大文件分块并行下载。所有分块下载完后再合并、校验，失败时不会留下完整文件。
  Future<void> _downloadChunked(DownloadItem item, int size, bool Function()? cancelled) async {
    if (cancelled?.call() ?? false) throw const _Cancelled();
    final f = File(item.path);
    await f.parent.create(recursive: true);
    final base = '${item.path}.$pid.${_tmpSeq++}';
    final chunks = <File>[];
    File? merged;
    try {
      final chunkSize = (size + _chunkCount - 1) ~/ _chunkCount;
      final futures = <Future<void>>[];
      for (var i = 0; i < _chunkCount; i++) {
        final start = i * chunkSize;
        if (start >= size) break;
        final end = min(start + chunkSize, size) - 1;
        final part = File('$base.$i.part');
        chunks.add(part);
        futures.add(() async {
          final bytes = await _get(item.url, range: 'bytes=$start-$end', cancelled: cancelled);
          if (bytes.length != end - start + 1) throw Exception('分块大小不符：${part.path}');
          await part.writeAsBytes(bytes, flush: true);
        }());
      }
      await Future.wait(futures);
      if (cancelled?.call() ?? false) throw const _Cancelled();
      merged = File('$base.tmp');
      final sink = merged.openWrite();
      try {
        for (final part in chunks) {
          await sink.addStream(part.openRead());
        }
      } finally {
        await sink.close();
      }
      if (await merged.length() != size) throw Exception('分块合并后大小不符：${item.path}');
      final want = item.sha1?.toLowerCase();
      if (want != null && want.isNotEmpty) {
        final actual = (await sha1.bind(merged.openRead()).first).toString();
        if (actual != want) throw Exception('校验失败（SHA-1 不匹配）：${item.path}');
      }
      if (cancelled?.call() ?? false) throw const _Cancelled();
      await merged.rename(item.path);
      merged = null;
      if (want != null && want.isNotEmpty) {
        try {
          VerifiedFiles.record(item.path, await f.stat(), want);
        } on FileSystemException {
          // 记录失败只会导致下次重新校验
        }
      }
    } finally {
      for (final part in chunks) {
        try {
          await part.delete();
        } catch (_) {}
      }
      if (merged != null) {
        try {
          await merged.delete();
        } catch (_) {}
      }
    }
  }

  /// 流式下载到文件：边下边写，按字节报告进度。用于大文件（例如安卓的 Java），
  /// 20 秒没有新数据、速度长期过低或大小不符时中断，方便调用方换一个下载源重试。
  Future<void> downloadStreamed(
    DownloadItem item, {
    void Function(int received, int total)? onProgress,
    void Function(String message)? onInfo,
  }) async {
    final target = mirror(item.url);
    final req = await _client.getUrl(Uri.parse(target));
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('下载失败（HTTP ${res.statusCode}）');
    }
    final total = res.contentLength > 0 ? res.contentLength : (item.size ?? 0);
    onInfo?.call(
      '已连接 ${Uri.parse(target).host}'
      '${total > 0 ? '，文件大小 ${(total / 1048576).toStringAsFixed(1)} MB' : '，服务器没有提供文件大小'}',
    );
    final out = File(item.path);
    await out.parent.create(recursive: true);
    final tmp = File('${item.path}.$pid.${_tmpSeq++}.tmp');
    final sink = tmp.openWrite();
    var received = 0;
    final watch = Stopwatch()..start();
    onProgress?.call(0, total);
    try {
      // 20 秒没有新数据视为连接卡住，抛出 TimeoutException 让调用方换源
      await for (final chunk in res.timeout(const Duration(seconds: 20))) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
        final secs = watch.elapsedMilliseconds / 1000;
        if (secs > 15 && received / secs < 24 * 1024) {
          throw HttpException('下载速度过慢（${(received / secs / 1024).toStringAsFixed(0)} KB/s）');
        }
      }
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await tmp.delete();
      } catch (_) {}
      rethrow;
    }
    await sink.close();
    if (received == 0) throw HttpException('没有收到数据');
    if (total > 0 && received != total) {
      await tmp.delete().catchError((_) => tmp);
      throw HttpException('下载不完整（$received / $total 字节）');
    }
    if (item.size != null && received != item.size) {
      await tmp.delete().catchError((_) => tmp);
      throw HttpException('下载不完整（应为 ${item.size} 字节，实际 $received）');
    }
    if (out.existsSync()) await out.delete();
    await tmp.rename(out.path);
  }

  /// 并发下载，跳过已完整的文件。[onBytes] 可选，按字节报告已完成的大小
  Future<void> downloadAll(
    List<DownloadItem> items,
    void Function(int done, int total) onProgress, {
    void Function(int done, int total)? onBytes,
    bool Function()? cancelled,
  }) async {
    final unique = {for (final i in items) i.path: i}.values.toList();
    final jobs = <_Job>[];
    // 检查本地文件：第一次需要计算 SHA-1，并行进行
    var next = 0;
    Future<void> checker() async {
      while (next < unique.length) {
        final item = unique[next++];
        if (!await isComplete(item)) jobs.add(_Job(item));
      }
    }

    await Future.wait([for (var i = 0; i < 8; i++) checker()]);
    await VerifiedFiles.save();
    // 大文件先下，免得最后剩下几个大文件单线程慢慢下
    jobs.sort((a, b) => (b.item.size ?? 0).compareTo(a.item.size ?? 0));
    var done = 0;
    final total = jobs.length;
    final totalBytes = jobs.fold<int>(0, (s, j) => s + (j.item.size ?? 0));
    var doneBytes = 0;
    onProgress(0, total);
    if (onBytes != null && totalBytes > 0) onBytes(0, totalBytes);
    if (total == 0) return;

    final errors = <Object>[];
    final allDone = Completer<void>();
    void finish(_Job job) {
      if (job.finished) return;
      job.finished = true;
      job.done.complete();
      onProgress(++done, total);
      if (onBytes != null && totalBytes > 0) {
        doneBytes += job.item.size ?? 0;
        onBytes(doneBytes, totalBytes);
      }
      if (done == total) allDone.complete();
    }

    Future<void> run(_Job job) async {
      job.running++;
      job.startedAt ??= DateTime.now();
      try {
        if (cancelled?.call() ?? false) throw const _Cancelled();
        // 同一文件可能已经由补位连接完成；完成后立即释放 worker 去下载下一个文件，
        // 不再等这条卡住的连接自然超时。
        final download = downloadFile(job.item, cancelled: () => job.finished || (cancelled?.call() ?? false));
        await Future.any<void>([download, job.done.future]);
        if (!job.finished) finish(job);
      } catch (e) {
        job.error ??= e;
      } finally {
        job.running--;
        // 所有连接都失败才算失败
        if (!job.finished && job.running == 0) {
          errors.add(job.error!);
          finish(job);
        }
      }
    }

    var cursor = 0;
    Future<void> worker() async {
      while (cursor < jobs.length) {
        await run(jobs[cursor++]);
      }
    }

    // 独立于 worker 的补位连接：worker 可能都被慢文件占住，
    // 由这个循环在后台给慢文件再开连接，避免结尾被一两个节点拖住。
    Future<void> hedgeLoop() async {
      const maxPerJob = 3;
      while (!allDone.isCompleted) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (allDone.isCompleted) return;
        final active = jobs
            .where((j) => !j.finished && j.running > 0)
            .where((j) => DateTime.now().difference(j.startedAt!).inMilliseconds >= 2000)
            .toList();
        for (final job in active) {
          if (job.running >= maxPerJob) continue;
          unawaited(run(job));
        }
      }
    }

    // 全部文件有结果就返回，不等被淘汰的连接超时
    for (var i = 0; i < max(1, min(concurrency, 64)); i++) {
      unawaited(worker());
    }
    unawaited(hedgeLoop());
    await allDone.future;
    await VerifiedFiles.save();
    if (errors.isNotEmpty) throw Exception('${errors.length} 个文件下载失败，例如：${errors.first}');
  }
}

/// downloadAll 中的一个文件，可能同时有两个连接在下载
class _Job {
  _Job(this.item);

  final DownloadItem item;
  final done = Completer<void>();
  DateTime? startedAt;
  var running = 0;
  var finished = false;
  Object? error;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _RangeUnsupported implements Exception {
  const _RangeUnsupported();
}

/// 已经按 SHA-1 校验过的文件：路径 → 大小、修改时间与 SHA-1。
/// 文件大小或修改时间变化后会重新校验。保存在启动器数据目录的 verified-files.json。
abstract final class VerifiedFiles {
  /// 由启动器在启动时设置；未设置时只在内存中记录（例如测试）
  static String? storePath;

  static Map<String, String>? _entries;
  static var _dirty = false;

  static Map<String, String> get _map {
    if (_entries != null) return _entries!;
    var loaded = <String, String>{};
    final path = storePath;
    if (path != null) {
      try {
        final j = jsonDecode(File(path).readAsStringSync());
        if (j is Map) loaded = {for (final e in j.entries) '${e.key}': '${e.value}'};
      } catch (_) {
        // 文件不存在或损坏：从空记录开始，只是需要重新校验
      }
    }
    return _entries = loaded;
  }

  static String _value(FileStat stat, String sha1) => '${stat.size}:${stat.modified.millisecondsSinceEpoch}:$sha1';

  static bool matches(String path, FileStat stat, String sha1) => _map[path] == _value(stat, sha1);

  static void record(String path, FileStat stat, String sha1) {
    final v = _value(stat, sha1);
    if (_map[path] == v) return;
    _map[path] = v;
    _dirty = true;
  }

  static Future<void> save() async {
    final path = storePath;
    if (path == null || !_dirty) return;
    _dirty = false;
    try {
      final tmp = File('$path.tmp');
      await tmp.writeAsString(jsonEncode(_map), flush: true);
      await tmp.rename(path);
    } catch (_) {
      // 保存失败只会导致下次重新校验
    }
  }
}
