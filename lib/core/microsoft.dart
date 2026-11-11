import 'accounts.dart';
import 'auth/auth.dart';
import 'auth/http_json.dart';
import 'auth/oauth.dart';

const _msAuth = 'https://login.microsoftonline.com/consumers/oauth2/v2.0';
const _scope = 'XboxLive.signin offline_access';

OAuthClient _oauth(String clientId) => OAuthClient(
  clientId: clientId.trim(),
  deviceEndpoint: '$_msAuth/devicecode',
  tokenEndpoint: '$_msAuth/token',
);

Future<(int, Map<String, dynamic>)> _request(String method, String url, {Object? json, String? bearer}) async {
  final r = await requestJson(method, url, json: json, bearer: bearer);
  return (r.status, r.map);
}

/// Xbox 的错误码转为可读的说明
Never _xboxError(int status, Map<String, dynamic> data, String url) {
  switch (data['XErr']) {
    case 2148916233:
      throw Exception('该微软账户尚未创建 Xbox 档案');
    case 2148916238:
      throw Exception('未成年账户需要加入家庭组后才能登录');
  }
  throw Exception('请求失败（$status）：$url');
}

Future<Map<String, dynamic>> _postJson(String url, Object body) async {
  final (status, data) = await _request('POST', url, json: body);
  if (status >= 400) _xboxError(status, data, url);
  return data;
}

/// 用微软令牌换取 Minecraft 令牌与档案
Future<Account> _minecraftFromMs(String msAccess, String msRefresh) async {
  final xbl = await _postJson('https://user.auth.xboxlive.com/user/authenticate', {
    'Properties': {'AuthMethod': 'RPS', 'SiteName': 'user.auth.xboxlive.com', 'RpsTicket': 'd=$msAccess'},
    'RelyingParty': 'http://auth.xboxlive.com',
    'TokenType': 'JWT',
  });
  final xsts = await _postJson('https://xsts.auth.xboxlive.com/xsts/authorize', {
    'Properties': {
      'SandboxId': 'RETAIL',
      'UserTokens': [xbl['Token']],
    },
    'RelyingParty': 'rp://api.minecraftservices.com/',
    'TokenType': 'JWT',
  });
  final uhs = (((xbl['DisplayClaims'] as Map)['xui'] as List).first as Map)['uhs'];
  final mc = await _postJson('https://api.minecraftservices.com/authentication/login_with_xbox', {
    'identityToken': 'XBL3.0 x=$uhs;${xsts['Token']}',
  });
  final mcToken = '${mc['access_token']}';
  final (status, profile) = await _request(
    'GET',
    'https://api.minecraftservices.com/minecraft/profile',
    bearer: mcToken,
  );
  if (status == 404) throw Exception('该账户没有购买 Minecraft: Java Edition');
  if (status >= 400) throw Exception('获取档案失败（$status）');
  return Account(
    id: newId(),
    type: AccountType.microsoft,
    name: '${profile['name']}',
    uuid: '${profile['id']}',
    accessToken: mcToken,
    refreshToken: msRefresh,
    expiresAt: DateTime.now().millisecondsSinceEpoch + ((mc['expires_in'] as num?)?.toInt() ?? 86400) * 1000,
  );
}

/// 微软账户的设备代码登录。用户在浏览器中输入代码，这里轮询直到完成。
class MicrosoftLogin implements LoginCommand {
  MicrosoftLogin(this.clientId, this.onCode);

  final String clientId;
  final void Function(DeviceCode) onCode;
  bool _cancelled = false;

  @override
  void cancel() => _cancelled = true;

  @override
  Future<Account> execute() async {
    if (clientId.trim().isEmpty) throw Exception('请先在「设置 - 其他」中填写 Azure 应用 Client ID');
    final t = await _oauth(clientId).deviceLogin(_scope, onCode, cancelled: () => _cancelled);
    return _minecraftFromMs(t.accessToken, '${t.refreshToken}');
  }
}

/// 微软账户启动前的处理：令牌快过期时刷新
class MicrosoftAuth implements AccountAuth {
  const MicrosoftAuth(this.clientId);

  final String clientId;

  @override
  Future<AuthSession> prepare(Account acc, AuthPrompts prompts) async =>
      (account: await refreshIfNeeded(acc, clientId), jvmArgs: const <String>[]);
}

/// 启动前刷新即将过期的微软账户
Future<Account> refreshIfNeeded(Account acc, String clientId) async {
  final expiresAt = acc.expiresAt ?? 0;
  if (acc.type != AccountType.microsoft || expiresAt > DateTime.now().millisecondsSinceEpoch + 5 * 60000) return acc;
  // 从 PCL-CE 导入的令牌无法用本启动器的 Client ID 刷新
  if (acc.importedLegacy) {
    final expired = Exception('账户 ${acc.name} 的登录已过期（导入自 PCL-CE，无法续期），请使用微软登录重新添加');
    if (acc.expiresAt != null) throw expired;
    // 没有记录过期时间：向档案接口确认令牌是否仍然有效；网络问题时照常启动
    final int status;
    try {
      (status, _) = await _request(
        'GET',
        'https://api.minecraftservices.com/minecraft/profile',
        bearer: acc.accessToken,
      );
    } catch (_) {
      return acc;
    }
    if (status == 401 || status == 403) throw expired;
    return acc;
  }
  if (clientId.trim().isEmpty || acc.refreshToken == null) throw Exception('微软账户已过期，请重新登录');
  final t = await _oauth(clientId).refresh(acc.refreshToken!, scope: _scope);
  if (t == null) throw Exception('微软账户已过期，请重新登录');
  return (await _minecraftFromMs(t.accessToken, t.refreshToken ?? acc.refreshToken!)).copyWith(id: acc.id);
}
