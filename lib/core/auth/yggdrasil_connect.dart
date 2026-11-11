import 'dart:convert';

import '../accounts.dart';
import 'auth.dart';
import 'authlib_injector.dart';
import 'http_json.dart';
import 'oauth.dart';
import 'yggdrasil_api.dart';

/// Yggdrasil Connect：基于 OpenID Connect 的外置登录。用设备代码流取得访问令牌，
/// 访问令牌直接作为游戏的 accessToken 交给 authlib-injector
abstract final class YggdrasilConnect {
  /// 内置支持的皮肤站（域名）与本启动器在该站注册的 OAuth client_id。增删站点只需要改这里
  static const builtInClientIds = {'littleskin.cn': '/* ur littleskin cilent id */'};

  /// 申请的权限：ID 令牌、刷新令牌、授权时选择角色、进入多人游戏服务器
  static const scope = 'openid offline_access Yggdrasil.PlayerProfiles.Select Yggdrasil.Server.Join';

  static const _requiredScopes = ['openid', 'Yggdrasil.PlayerProfiles.Select', 'Yggdrasil.Server.Join'];

  /// 地址（如 littleskin.cn、https://littleskin.cn/api/yggdrasil）对应的内置站点，按域名匹配、不联网；
  /// 不是内置站点时返回 null，只能用账户密码登录
  static String? builtInSite(String address) {
    final s = address.trim();
    final host = Uri.tryParse(s.contains('://') ? s : 'https://$s')?.host.toLowerCase();
    return builtInClientIds.containsKey(host) ? host : null;
  }

  static String? clientIdFor(String apiRoot) => builtInClientIds[builtInSite(apiRoot)];
}

/// 验证服务器的 OpenID 提供者（服务发现：authlib-injector 元数据 → OpenID 提供者元数据）
class _Provider {
  _Provider(this.server, Map<String, dynamic> j)
    : issuer = '${j['issuer']}',
      tokenEndpoint = '${j['token_endpoint']}',
      deviceEndpoint = j['device_authorization_endpoint'] as String?,
      sharedClientId = j['shared_client_id'] as String?;

  final YggdrasilServer server;
  final String issuer;
  final String tokenEndpoint;
  final String? deviceEndpoint;
  final String? sharedClientId;

  static Future<_Provider> discover(YggdrasilServer server) async {
    final url = server.openIdConfigurationUrl;
    // Yggdrasil Connect 只允许 HTTPS
    if (url == null || !url.startsWith('https://')) throw Exception('${server.name} 不支持 Yggdrasil Connect');
    final r = await requestJson('GET', url);
    final scopes = (r.map['scopes_supported'] as List?) ?? const [];
    if (!r.ok || r.map['token_endpoint'] == null || !YggdrasilConnect._requiredScopes.every(scopes.contains)) {
      throw Exception('${server.name} 的 Yggdrasil Connect 配置无效');
    }
    return _Provider(server, r.map);
  }

  /// 内置的 client_id 优先，其次是服务器预注册的公用应用
  String get clientId =>
      YggdrasilConnect.clientIdFor(server.root) ??
      sharedClientId ??
      (throw Exception('启动器尚未在 ${server.name} 注册应用，暂时无法使用 OAuth 登录'));

  OAuthClient oauth(String clientId) =>
      OAuthClient(clientId: clientId, tokenEndpoint: tokenEndpoint, deviceEndpoint: deviceEndpoint);

  GameProfile? profileFrom(String? idToken, String clientId) =>
      idToken == null ? null : idTokenProfile(idToken, issuer: issuer, clientId: clientId);
}

/// 检查 ID 令牌的签发者、受众与有效期（允许 5 分钟时钟误差），取出授权时选择的角色。
/// ID 令牌是经 HTTPS 直接从令牌端点取得的，按 OpenID Connect Core 3.1.3.7 可以用 TLS 代替签名验证
GameProfile? idTokenProfile(String idToken, {required String issuer, required String clientId, DateTime? now}) {
  final parts = idToken.split('.');
  if (parts.length != 3) throw const FormatException('ID 令牌格式错误');
  final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map<String, dynamic>;
  final aud = claims['aud'];
  final t = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  const skew = 300;
  if (claims['iss'] != issuer ||
      !(aud == clientId || (aud is List && aud.contains(clientId))) ||
      ((claims['exp'] as num?) ?? 0) < t - skew ||
      ((claims['iat'] as num?) ?? 0) > t + skew) {
    throw Exception('ID 令牌无效（签发者、受众或有效期不符）');
  }
  return GameProfile.tryParse(claims['selectedProfile']);
}

/// Yggdrasil Connect 设备代码登录：用户在皮肤站页面授权并选择角色
class ConnectLogin implements LoginCommand {
  ConnectLogin(this.site, this.onCode);

  /// 皮肤站地址（如 littleskin.cn），按 authlib-injector 规范解析出 API 根地址
  final String site;
  final void Function(DeviceCode) onCode;
  bool _cancelled = false;

  @override
  void cancel() => _cancelled = true;

  @override
  Future<Account> execute() async {
    final op = await _Provider.discover(await YggdrasilServer.resolve(site));
    if (op.deviceEndpoint == null) throw Exception('${op.server.name} 不支持设备代码登录');
    final clientId = op.clientId;
    final t = await op.oauth(clientId).deviceLogin(YggdrasilConnect.scope, onCode, cancelled: () => _cancelled);
    final profile = op.profileFrom(t.idToken, clientId) ?? (throw Exception('授权时没有选择角色'));
    return Account(
      id: newId(),
      type: AccountType.yggdrasilConnect,
      name: profile.name,
      uuid: profile.id,
      accessToken: t.accessToken,
      refreshToken: t.refreshToken,
      expiresAt: t.expiresAt,
      server: op.server.root,
      serverName: op.server.name,
      clientToken: clientId,
    );
  }
}

/// Yggdrasil Connect 账户启动前的处理：访问令牌快过期时用刷新令牌续期（刷新令牌只能用一次，新令牌会保存）；
/// 同时准备 authlib-injector
class ConnectAuth implements AccountAuth {
  const ConnectAuth(this.injector);

  final AuthlibInjector injector;

  @override
  Future<AuthSession> prepare(Account acc, AuthPrompts prompts) => injector.inject(_refreshIfNeeded(acc), acc.server!);

  Future<Account> _refreshIfNeeded(Account acc) async {
    if ((acc.expiresAt ?? 0) > DateTime.now().millisecondsSinceEpoch + 5 * 60000) return acc;
    final expired = Exception('${acc.typeLabel} 账户 ${acc.name} 的授权已过期，请在账户中重新登录');
    if (acc.refreshToken == null) throw expired;
    final op = await _Provider.discover(await YggdrasilServer.fetch(acc.server!));
    final clientId = acc.clientToken ?? op.clientId;
    final t = await op.oauth(clientId).refresh(acc.refreshToken!);
    if (t == null) throw expired;
    GameProfile? profile;
    try {
      profile = op.profileFrom(t.idToken, clientId);
    } catch (_) {
      // 刷新令牌已经用掉，ID 令牌有问题也要保存新令牌，只是不更新角色名
    }
    return acc.copyWith(
      name: profile?.name,
      accessToken: t.accessToken,
      refreshToken: t.refreshToken,
      expiresAt: t.expiresAt,
    );
  }
}
