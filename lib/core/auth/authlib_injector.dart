import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../accounts.dart';
import '../download.dart';
import '../paths.dart';
import 'auth.dart';
import 'yggdrasil_api.dart';

/// authlib-injector：让游戏使用外置验证服务器。负责缓存 jar 并生成 JVM 参数（authlib-injector 启动器规范「启动游戏」）
class AuthlibInjector {
  AuthlibInjector(this.dl);

  final Downloader dl;

  /// 官方下载接口；选择 BMCLAPI 下载源时由 [Downloader.mirror] 换成镜像
  static const latestUrl = 'https://authlib-injector.yushi.moe/artifact/latest.json';

  /// 存放 jar 的目录；Windows 上路径含非 ASCII 字符时换到 ProgramData（与 natives 目录相同的处理）
  static String get dir {
    final preferred = p.join(Paths.appData, 'authlib-injector');
    if (!Platform.isWindows || preferred.codeUnits.every((c) => c < 0x80)) return preferred;
    return p.join(Platform.environment['ProgramData'] ?? r'C:\ProgramData', 'PCL.PW', 'authlib-injector');
  }

  /// 与账户验证并行准备 authlib-injector（规范建议并行），两者都完成后返回
  Future<AuthSession> inject(Future<Account> account, String apiRoot) async {
    final r = await Future.wait<Object>([account, jvmArgs(apiRoot)]);
    return (account: r[0] as Account, jvmArgs: r[1] as List<String>);
  }

  /// `-javaagent` 与预取的 API 元数据（避免游戏启动时再联网获取）；预取失败时由 authlib-injector 自己获取
  Future<List<String>> jvmArgs(String apiRoot) async {
    final meta = YggdrasilServer.fetch(apiRoot).then<String?>((s) => s.metadataText, onError: (_) => null);
    final jar = await _jar();
    final prefetched = await meta;
    return [
      '-javaagent:$jar=$apiRoot',
      if (prefetched != null) '-Dauthlibinjector.yggdrasil.prefetched=${base64Encode(utf8.encode(prefetched))}',
    ];
  }

  /// jar 的路径：每天最多检查一次新版本，检查或下载失败时继续用已有的 jar
  Future<String> _jar() async {
    final jar = File(p.join(dir, 'authlib-injector.jar'));
    final checked = File(p.join(dir, 'latest.json'));
    final fresh =
        checked.existsSync() && DateTime.now().difference(checked.lastModifiedSync()) < const Duration(days: 1);
    if (jar.existsSync() && fresh) return jar.path;
    try {
      final latest = await dl.fetchJson(latestUrl) as Map<String, dynamic>;
      final want = '${(latest['checksums'] as Map)['sha256']}'.toLowerCase();
      if (!jar.existsSync() || sha256.convert(await jar.readAsBytes()).toString() != want) {
        final tmp = File('${jar.path}.download');
        await dl.downloadFile(DownloadItem(url: '${latest['download_url']}', path: tmp.path));
        if (sha256.convert(await tmp.readAsBytes()).toString() != want) {
          await tmp.delete();
          throw Exception('校验失败（SHA-256 不匹配）');
        }
        await tmp.rename(jar.path);
      }
      await checked.writeAsString(jsonEncode(latest));
    } catch (e) {
      if (!jar.existsSync()) throw Exception('无法下载 authlib-injector：$e');
    }
    return jar.path;
  }
}
