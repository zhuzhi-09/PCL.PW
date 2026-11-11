import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'paths.dart';

import '../../core/accounts.dart';
import '../../core/cat_ini.dart';
import '../../core/config.dart';
import '../../core/secure.dart';

/// 从 PCL-CE 导入全局设置、游戏文件夹与账户。
/// 全局配置分两处（PCL.Core/App/Configuration/ConfigService.cs）：
///  - 共享配置：%APPDATA%\PCLCE\config.v1.json
///  - 本地配置：`<PCL 所在目录>\PCL\config.v1.yml`（旧版为 setup.ini）

String get pclSharedDir => pclCompatSharedDir;

Map<String, dynamic>? _readShared() {
  for (final f in [
    p.join(pclSharedDir, 'config.v1.json'),
    p.join(pclSharedDir, 'config.json'),
    p.join(pclCompatAppData, '.PCLCE', 'Config.json'),
  ]) {
    final file = File(f);
    if (!file.existsSync()) continue;
    try {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      // 尝试下一个
    }
  }
  return null;
}

Map<String, dynamic> _readLocal(String? pclDir) {
  if (pclDir == null) return {};
  final yml = File(p.join(pclDir, 'PCL', 'config.v1.yml'));
  if (yml.existsSync()) {
    try {
      final doc = loadYaml(yml.readAsStringSync());
      if (doc is YamlMap) return {for (final e in doc.entries) '${e.key}': e.value};
    } catch (_) {
      return {};
    }
  }
  return readCatIni(pclInstanceLegacyConfig(pclDir));
}

/// PCL 的 LaunchFolders：`名称>路径\|名称>路径\`
List<GameFolder> _parseFolders(Object? raw, String? pclDir) => [
  for (final f in '${raw ?? ''}'.split('|'))
    if (f.contains('>'))
      () {
        final i = f.indexOf('>');
        var path = f.substring(i + 1);
        if (pclDir != null) path = path.replaceFirst(r'$', '$pclDir\\');
        path = path.replaceAll(RegExp(r'[\\/]+$'), '');
        return GameFolder(name: f.substring(0, i), path: path, custom: true);
      }(),
].where((f) => f.path.isNotEmpty && !f.path.contains(r'$') && Directory(f.path).existsSync()).toList();

// ---------- 枚举映射（JSON 中为名称，YAML / 旧版中可能为数字） ----------

T? _enum<T>(Object? v, List<String> names, List<T> map) {
  if (v == null || v == '') return null;
  final s = '$v';
  final i = RegExp(r'^\d+$').hasMatch(s) ? int.parse(s) : names.indexWhere((n) => n.toLowerCase() == s.toLowerCase());
  return i >= 0 && i < map.length ? map[i] : null;
}

String? _windowMode(Object? v) => _enum(
  v,
  ['Fullscreen', 'Default', 'Launcher', 'Custom', 'Maximized'],
  ['fullscreen', 'default', 'launcher', 'custom', 'maximized'],
);
String? _visibility(Object? v) => _enum(
  v,
  ['ExitImmediately', 'ObsoleteCaseDoNotUse', 'HideAndExit', 'HideAndReopen', 'MinimizeAndReopen', 'DoNothing'],
  ['exit', 'hideAndExit', 'hideAndExit', 'hideAndReopen', 'minimizeAndReopen', 'keep'],
);
String? _priority(Object? v) => _enum(
  v,
  ['AboveNormal', 'Normal', 'BelowNormal', 'High', 'RealTime'],
  ['aboveNormal', 'normal', 'belowNormal', 'high', 'realtime'],
);
String? _ipStack(Object? v) => _enum(v, ['PreferV4', 'Default', 'PreferV6'], ['v4', 'default', 'v6']);

int? _num(Object? v) => v == null || v == '' ? null : num.tryParse('$v')?.toInt();
String? _str(Object? v) => v?.toString();
bool? _bool(Object? v) =>
    v == null || v == '' ? null : v == true || RegExp(r'^(true|1)$', caseSensitive: false).hasMatch('$v');

// ---------- 账户解密（PCL.Core/Utils/Secret/EncryptHelper.cs 与 PlainToolkit.CngProtectedData） ----------
//
//   UserKey.bin = EncryptionData(version 1: CAPI DPAPI | version 2: CNG DPAPI)，解出 32 字节用户密钥
//   加密值     = base64(EncryptionData(version 0: ChaCha20 | 1: ChaCha20-Poly1305 | 2: AES-GCM))

final _entropy = utf8.encode('PCL CE Encryption Key');
const _dataMagic = 0x454e4321; // "ENC!"，大端
const _cpdMagic = 0x5f445043; // "CPD_"，小端（结构体直接写入内存）

({int version, Uint8List data})? _parseEncryptionData(Uint8List buf) {
  if (buf.length < 12) return null;
  final d = ByteData.sublistView(buf);
  if (d.getUint32(0) != _dataMagic) return null;
  final len = d.getInt32(8);
  if (len < 0 || len > buf.length - 12) throw Exception('加密数据长度无效');
  return (version: d.getUint32(4), data: buf.sublist(12, 12 + len));
}

/// CNG DPAPI 没有现成的 Dart 绑定，与 Electron 版一样通过 PowerShell 调用
const _ncryptPs = r'''
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PwNcrypt {
  [DllImport("ncrypt.dll")]
  public static extern int NCryptUnprotectSecret(out IntPtr desc, uint flags, byte[] blob, uint cb,
    IntPtr memPara, IntPtr hwnd, out IntPtr data, out uint cbData);
  [DllImport("ncrypt.dll")] public static extern int NCryptCloseProtectionDescriptor(IntPtr desc);
  [DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr mem);
  public static string Unprotect(string b64) {
    byte[] blob = Convert.FromBase64String(b64);
    IntPtr desc, data; uint cb;
    int hr = NCryptUnprotectSecret(out desc, 0, blob, (uint)blob.Length, IntPtr.Zero, IntPtr.Zero, out data, out cb);
    if (hr != 0) throw new Exception("NCryptUnprotectSecret 0x" + hr.ToString("X"));
    try { byte[] o = new byte[cb]; Marshal.Copy(data, o, 0, (int)cb); return Convert.ToBase64String(o); }
    finally { LocalFree(data); if (desc != IntPtr.Zero) NCryptCloseProtectionDescriptor(desc); }
  }
}
"@
[Console]::Out.Write([PwNcrypt]::Unprotect($env:PW_BLOB))
''';

Future<Uint8List> _ncryptUnprotect(Uint8List blob) async {
  final r = await Process.run(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', _ncryptPs],
    environment: {'PW_BLOB': base64Encode(blob)},
  ).timeout(const Duration(seconds: 30));
  if (r.exitCode != 0) throw Exception('${r.stderr}'.trim());
  return base64Decode('${r.stdout}'.trim());
}

/// PlainToolkit.CngProtectedData 的解包：[header 8][nonce 12][ciphertext][tag 16]，熵通过 AES-GCM 模拟
Future<Uint8List> _cpdUnpack(Uint8List packed) async {
  if (packed.length < 8 || ByteData.sublistView(packed).getUint32(0, Endian.little) != _cpdMagic) {
    throw Exception('无法识别的 CNG 保护数据');
  }
  final hasEntropy = (packed[5] & 1) != 0;
  if (!hasEntropy) return packed.sublist(8);
  final key = (await Sha256().hash(_entropy)).bytes;
  final plain = await AesGcm.with256bits().decrypt(
    SecretBox(
      packed.sublist(20, packed.length - 16),
      nonce: packed.sublist(8, 20),
      mac: Mac(packed.sublist(packed.length - 16)),
    ),
    secretKey: SecretKey(key),
    aad: packed.sublist(0, 8),
  );
  return Uint8List.fromList(plain);
}

/// 读取并解开 %APPDATA%\PCLCE\UserKey.bin
Future<Uint8List> _loadUserKey() async {
  if (!Platform.isWindows) throw Exception('PCL-CE 的账户密钥只能在 Windows 上解开');
  final f = File(p.join(pclSharedDir, 'UserKey.bin'));
  if (!f.existsSync()) throw Exception('找不到 PCL-CE 用户密钥 UserKey.bin');
  final ed = _parseEncryptionData(f.readAsBytesSync());
  if (ed == null) throw Exception('UserKey.bin 格式无法识别');
  return switch (ed.version) {
    2 => _cpdUnpack(await _ncryptUnprotect(ed.data)),
    1 => SecureData.unprotect(ed.data, entropy: _entropy),
    _ => throw Exception('不支持的 UserKey 版本 ${ed.version}'),
  };
}

/// 对应 EncryptHelper.SecretDecrypt
Future<String> _secretDecrypt(String value, Uint8List key) async {
  if (value.isEmpty) return '';
  final ed = _parseEncryptionData(base64Decode(value));
  // 非常老的 PCL 使用与硬件绑定的 AES-CBC 密钥，这里不支持
  if (ed == null) throw Exception('旧版加密格式，不支持导入');
  final d = ed.data;
  final List<int> plain;
  switch (ed.version) {
    case 2:
      // [nonce 12][tag 16][ciphertext]
      plain = await AesGcm.with256bits().decrypt(
        SecretBox(d.sublist(28), nonce: d.sublist(0, 12), mac: Mac(d.sublist(12, 28))),
        secretKey: SecretKey(key),
      );
    case 1:
      // [salt 16][nonce 12][tag 16][ciphertext]，密钥经 HKDF-SHA256 派生
      final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(key),
        nonce: d.sublist(0, 16),
        info: utf8.encode('PCL.Core.Utils.Encryption.ChaCha20'),
      );
      plain = await Chacha20.poly1305Aead().decrypt(
        SecretBox(d.sublist(44), nonce: d.sublist(16, 28), mac: Mac(d.sublist(28, 44))),
        secretKey: derived,
      );
    case 0:
      // [nonce 12][ciphertext]，纯 ChaCha20，计数器从 0 开始
      plain = await Chacha20(macAlgorithm: MacAlgorithm.empty).decrypt(
        SecretBox(d.sublist(12), nonce: d.sublist(0, 12), mac: Mac.empty),
        secretKey: SecretKey(key),
      );
    default:
      throw Exception('不支持的加密版本 ${ed.version}');
  }
  return utf8.decode(plain);
}

// ---------- 对外接口 ----------

class PclDetection {
  PclDetection({required this.found, required this.folders, required this.hasAccounts});

  final bool found;
  final int folders;
  final bool hasAccounts;
}

PclDetection detectPcl() {
  final shared = _readShared();
  if (shared == null) return PclDetection(found: false, folders: 0, hasAccounts: false);
  // 账户是加密的，这里只粗略判断是否存在
  final profile = shared['Profile'];
  return PclDetection(
    found: true,
    folders: _parseFolders(shared['LaunchFolders'], null).length,
    hasAccounts: profile is String && profile.length > 40,
  );
}

class PclImportResult {
  final settings = <String>[];
  int folders = 0;
  int accounts = 0;
  final skippedAccounts = <String>[];
  final warnings = <String>[];
}

Future<PclImportResult> importFromPcl(
  LauncherConfig cfg,
  AccountStore store, {
  required bool settings,
  required bool folders,
  required bool accounts,
  String? pclDir,
}) async {
  final shared = _readShared();
  if (shared == null && pclDir == null) throw Exception(r'没有找到 PCL-CE 的配置（%APPDATA%\PCLCE）');
  final s = shared ?? const <String, dynamic>{};
  final local = _readLocal(pclDir);
  final result = PclImportResult();
  final patch = <String, Object>{};
  void take(String key, Object? value, String label) {
    if (value == null) return;
    patch[key] = value;
    result.settings.add(label);
  }

  if (settings) {
    // 共享配置
    take('preferredIpStack', _ipStack(s['LaunchPreferredIpStack']), 'IP 协议偏好');
    take('gpuPreference', _bool(s['LaunchAdvanceGraphicCard']), '高性能显卡');
    take('afterLaunch', _visibility(s['LaunchArgumentVisible']), '启动后启动器行为');
    take('processPriority', _priority(s['LaunchArgumentPriority']), '进程优先级');
    final java = _str(s['LaunchArgumentJavaSelect']);
    if (java != null && File(java).existsSync()) take('javaPath', java, 'Java 选择');

    // 本地配置（需要 PCL 所在目录）
    if (pclDir != null) {
      final indie = _num(local['LaunchArgumentIndieV2']);
      if (indie != null && indie >= 0 && indie <= 4) take('isolationMode', indie, '版本隔离');
      final ramType = _num(local['LaunchRamType']);
      if (ramType != null) take('memoryMode', ramType == 1 ? 'custom' : 'auto', '内存模式');
      take('memoryTick', _num(local['LaunchRamCustom']), '自定义内存');
      take('memoryInitialTick', _num(local['LaunchRamCustomInitial']), '初始内存');
      take('lockMemory', _bool(local['LaunchAdvanceLockMemory']), '锁定内存');
      take('jvmArgs', _str(local['LaunchAdvanceJvm']), 'JVM 参数');
      take('gameArgs', _str(local['LaunchAdvanceGame']), '游戏参数');
      take('preLaunchCommand', _str(local['LaunchAdvanceRun']), '启动前命令');
      take('preLaunchWait', _bool(local['LaunchAdvanceRunWait']), '等待启动前命令');
      take('versionType', _str(local['LaunchArgumentInfo']), '版本类型');
      take('windowMode', _windowMode(local['LaunchArgumentWindowType']), '窗口模式');
      take('windowWidth', _num(local['LaunchArgumentWindowWidth']), '窗口宽度');
      take('windowHeight', _num(local['LaunchArgumentWindowHeight']), '窗口高度');
    } else {
      result.warnings.add('内存、JVM 参数、版本隔离等设置保存在 PCL-CE 程序目录中，选择该目录后才能导入');
    }
  }

  if (folders) {
    final found = _parseFolders(s['LaunchFolders'], pclDir);
    // PCL 程序目录下的 .minecraft 也算
    if (pclDir != null && Directory(p.join(pclDir, '.minecraft', 'versions')).existsSync()) {
      found.add(GameFolder(name: 'PCL-CE 文件夹', path: p.join(pclDir, '.minecraft'), custom: true));
    }
    final list = [...cfg.gameFolders];
    for (final f in found) {
      if (list.any((g) => g.path.toLowerCase() == f.path.toLowerCase())) continue;
      list.add(f);
      result.folders++;
    }
    patch['gameFolders'] = [for (final f in list) f.toJson()];
    // PCL 当前选择的文件夹
    final selected = _str(local['LaunchFolderSelect'])
        ?.replaceFirst(r'$', '${pclDir ?? ''}\\')
        .replaceAll(RegExp(r'[\\/]+$'), '');
    if (selected != null && Directory(p.join(selected, 'versions')).existsSync()) {
      patch['gameDir'] = selected;
      final ver = _str(local['LaunchInstanceSelect']) ?? readPclSelectedVersion(selected);
      if (ver != null && ver.isNotEmpty && Directory(p.join(selected, 'versions', ver)).existsSync()) {
        patch['selectedVersion'] = ver;
      }
    }
  }

  if (accounts) {
    try {
      final raw = s['Profile'];
      if (raw is String && raw.isNotEmpty) {
        final text = raw.trimLeft().startsWith('{') ? raw : await _secretDecrypt(raw, await _loadUserKey());
        final json = jsonDecode(text) as Map<String, dynamic>;
        final lastUsed = (json['lastUsed'] as num?)?.toInt() ?? -1;
        final profiles = ((json['profiles'] as List?) ?? const []).cast<Map<String, dynamic>>();
        for (var i = 0; i < profiles.length; i++) {
          final pr = profiles[i];
          final type = _enum(
            pr['profileType'],
            ['Microsoft', 'Offline', 'Authlib', 'YggdrasilConnect'],
            ['microsoft', 'offline', 'authlib', 'yggdrasil'],
          );
          final name = '${pr['username'] ?? ''}';
          if (name.isEmpty) continue;
          if (type == 'authlib' || type == 'yggdrasil') {
            result.skippedAccounts.add('$name（外置登录账户不能导入，请在账户中重新登录）');
            continue;
          }
          final microsoft = type == 'microsoft';
          final acc = await store.importAccount(
            Account(
              id: newId(),
              type: microsoft ? AccountType.microsoft : AccountType.offline,
              name: name,
              uuid: '${pr['uuid'] ?? ''}'.replaceAll('-', ''),
              accessToken: '${pr['accessToken'] ?? ''}'.isEmpty ? newId() : '${pr['accessToken']}',
              expiresAt: DateTime.tryParse('${pr['expiresAt'] ?? ''}')?.millisecondsSinceEpoch,
              importedLegacy: microsoft,
            ),
          );
          result.accounts++;
          if (i == lastUsed) patch['selectedAccount'] = acc.id;
          // 导入了正版账号，与登录过一次正版账号等同
          if (microsoft) patch['hintBuy'] = true;
        }
      }
    } catch (e) {
      result.warnings.add('账户导入失败：$e');
    }
  }

  if (patch.isNotEmpty) await cfg.update(patch);
  return result;
}
