import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'paths.dart';
import 'secure.dart';

/// 账户类型：离线、微软、外置登录（Yggdrasil API，账户密码）、外置登录（Yggdrasil Connect，OAuth 授权）
enum AccountType { offline, microsoft, yggdrasil, yggdrasilConnect }

class Account {
  Account({
    required this.id,
    required this.type,
    required this.name,
    required this.uuid,
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.importedLegacy = false,
    this.server,
    this.serverName,
    this.login,
    this.clientToken,
  });

  final String id;
  final AccountType type;
  final String name;
  final String uuid;
  final String accessToken;
  final String? refreshToken;

  /// 毫秒时间戳
  final int? expiresAt;

  /// 从 PCL-CE 导入的微软账户：刷新令牌属于 PCL-CE 的应用，过期后需要重新登录
  final bool importedLegacy;

  /// 外置登录：authlib-injector API 根地址（不以 / 结尾）
  final String? server;

  /// 外置登录：验证服务器名称（元数据中的 serverName）
  final String? serverName;

  /// Yggdrasil API：登录用的账户（邮箱或用户名），令牌失效后重新输入密码时使用
  final String? login;

  /// Yggdrasil API 的 clientToken；Yggdrasil Connect 为 OAuth client_id（刷新令牌时必须与登录时相同）
  final String? clientToken;

  String get typeLabel => switch (type) {
    AccountType.offline => '离线账户',
    AccountType.microsoft => '微软账户',
    AccountType.yggdrasil || AccountType.yggdrasilConnect => '外置登录 · ${serverName ?? Uri.tryParse('$server')?.host}',
  };

  Account copyWith({
    String? id,
    String? name,
    String? accessToken,
    String? refreshToken,
    int? expiresAt,
    String? clientToken,
  }) => Account(
    id: id ?? this.id,
    type: type,
    name: name ?? this.name,
    uuid: uuid,
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    expiresAt: expiresAt ?? this.expiresAt,
    importedLegacy: importedLegacy,
    server: server,
    serverName: serverName,
    login: login,
    clientToken: clientToken ?? this.clientToken,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'name': name,
    'uuid': uuid,
    'accessToken': accessToken,
    'refreshToken': ?refreshToken,
    'expiresAt': ?expiresAt,
    if (importedLegacy) 'importedFrom': 'pcl',
    'server': ?server,
    'serverName': ?serverName,
    'login': ?login,
    'clientToken': ?clientToken,
  };

  static Account fromJson(Map<String, dynamic> j) => Account(
    id: '${j['id']}',
    type: AccountType.values.asNameMap()[j['type']] ?? AccountType.offline,
    name: '${j['name']}',
    uuid: '${j['uuid']}',
    accessToken: '${j['accessToken']}',
    refreshToken: j['refreshToken'] as String?,
    expiresAt: (j['expiresAt'] as num?)?.toInt(),
    importedLegacy: j['importedFrom'] == 'pcl',
    server: j['server'] as String?,
    serverName: j['serverName'] as String?,
    login: j['login'] as String?,
    clientToken: j['clientToken'] as String?,
  );
}

String _randomHex(int bytes) {
  final r = Random.secure();
  return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String newId() => _randomHex(16);

/// 与 Java UUID.nameUUIDFromBytes("OfflinePlayer:" + name) 一致
String offlineUuid(String name) {
  final h = md5.convert(utf8.encode('OfflinePlayer:$name')).bytes.toList();
  h[6] = (h[6] & 0x0f) | 0x30;
  h[8] = (h[8] & 0x3f) | 0x80;
  return h.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 账户列表，加密保存在应用数据目录的 accounts.dat（见 [SecureData]）
class AccountStore {
  AccountStore._(this.accounts);

  final List<Account> accounts;

  static File get _file => File(p.join(Paths.configDir, 'accounts.dat'));

  /// 早期版本明文保存的账户文件，读取后迁移到 accounts.dat
  static File get _legacyFile => File(p.join(Paths.configDir, 'accounts.json'));

  static List<Account> _parse(String text) =>
      (jsonDecode(text) as List).whereType<Map<String, dynamic>>().map(Account.fromJson).toList();

  static AccountStore load() {
    try {
      if (_file.existsSync()) {
        return AccountStore._(_parse(utf8.decode(SecureData.unprotect(_file.readAsBytesSync()))));
      }
      if (_legacyFile.existsSync()) {
        final store = AccountStore._(_parse(_legacyFile.readAsStringSync()));
        store._save().then((_) => _legacyFile.delete()).catchError((_) => _legacyFile);
        return store;
      }
    } catch (_) {
      // 文件损坏或无法解密时从空列表开始
    }
    return AccountStore._([]);
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    final text = jsonEncode([for (final a in accounts) a.toJson()]);
    await _file.writeAsBytes(SecureData.protect(Uint8List.fromList(utf8.encode(text))));
    unawaited(Paths.backupConfigFile(_file));
  }

  /// 添加或更新账户（同类型、同验证服务器、同 UUID 视为同一账户）
  Future<Account> upsert(Account acc) =>
      _put(acc, (a) => a.type == acc.type && a.server == acc.server && a.uuid == acc.uuid);

  /// 导入（PCL-CE）：离线账户按名称匹配，避免 UUID 生成方式不同导致重复；其他账户同 [upsert]
  Future<Account> importAccount(Account acc) => acc.type == AccountType.offline
      ? _put(acc, (a) => a.type == AccountType.offline && a.name == acc.name)
      : upsert(acc);

  Future<Account> _put(Account acc, bool Function(Account) same) async {
    final i = accounts.indexWhere(same);
    if (i >= 0) {
      acc = acc.copyWith(id: accounts[i].id);
      accounts[i] = acc;
    } else {
      accounts.add(acc);
    }
    await _save();
    return acc;
  }

  static final _namePattern = RegExp(r'^[A-Za-z0-9_]{3,16}$');

  static String? validateOfflineName(String name) => _namePattern.hasMatch(name) ? null : '用户名需为 3-16 位字母、数字或下划线';

  Future<Account> addOffline(String name) async {
    final error = validateOfflineName(name);
    if (error != null) throw Exception(error);
    final existing = accounts.indexWhere((a) => a.type == AccountType.offline && a.name == name);
    final acc = Account(
      id: existing >= 0 ? accounts[existing].id : newId(),
      type: AccountType.offline,
      name: name,
      uuid: offlineUuid(name),
      accessToken: _randomHex(16),
    );
    if (existing >= 0) {
      accounts[existing] = acc;
    } else {
      accounts.add(acc);
    }
    await _save();
    return acc;
  }

  Future<void> remove(String id) async {
    accounts.removeWhere((a) => a.id == id);
    await _save();
  }

  Account? find(String id) => accounts.where((a) => a.id == id).firstOrNull ?? accounts.firstOrNull;
}
