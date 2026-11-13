import 'auth.dart';
import 'http_json.dart';

/// 一个 authlib-injector 验证服务器：API 根地址与元数据
class YggdrasilServer {
  YggdrasilServer._(this.root, this.metadataText, this._meta);

  /// API 根地址，不以 / 结尾
  final String root;

  /// 原始元数据，启动时作为预取内容交给 authlib-injector
  final String metadataText;
  final Map<String, dynamic> _meta;

  String get name => _meta['serverName'] as String? ?? Uri.parse(root).host;

  /// Yggdrasil Connect 服务发现：OpenID 提供者元数据的地址；没有时说明服务器不支持 Yggdrasil Connect
  String? get openIdConfigurationUrl => _meta['feature.openid_configuration_url'] as String?;

  /// 按 authlib-injector 启动器规范解析用户输入的地址：没有协议时补全 https://（不降级为 http），
  /// 跟随重定向，再按 API 地址指示（ALI）响应头确定 API 根地址
  static Future<YggdrasilServer> resolve(String input) async {
    var url = input.trim();
    if (url.isEmpty) throw Exception('请输入验证服务器地址');
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) url = 'https://$url';
    var r = await requestJson('GET', url);
    final ali = r.headers.value('x-authlib-injector-api-location');
    if (ali != null) {
      final target = r.url.resolve(ali);
      if (target != r.url) r = await requestJson('GET', '$target');
    }
    return _parse(r);
  }

  /// 直接获取已知 API 根地址的元数据
  static Future<YggdrasilServer> fetch(String root) async => _parse(await requestJson('GET', root));

  static YggdrasilServer _parse(JsonResponse r) {
    final meta = r.map['meta'];
    if (!r.ok || meta is! Map<String, dynamic>) throw Exception('${r.url} 不是有效的验证服务器');
    return YggdrasilServer._(r.url.toString().replaceFirst(RegExp(r'/+$'), ''), r.body, meta);
  }
}

/// 验证服务器返回的错误（errorMessage 通常可以直接展示给用户）
class YggdrasilException implements Exception {
  const YggdrasilException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 登录或刷新的结果
class YggdrasilSession {
  YggdrasilSession(Map<String, dynamic> j)
    : accessToken = '${j['accessToken']}',
      clientToken = '${j['clientToken']}',
      selected = GameProfile.tryParse(j['selectedProfile']),
      available = [for (final p in (j['availableProfiles'] as List?) ?? const []) ?GameProfile.tryParse(p)];

  final String accessToken;
  final String clientToken;
  final GameProfile? selected;
  final List<GameProfile> available;
}

/// Yggdrasil API 的认证部分（/authserver）
class YggdrasilClient {
  const YggdrasilClient(this.root);

  final String root;

  Future<YggdrasilSession> authenticate(String username, String password, String clientToken) => _post('authenticate', {
    'username': username,
    'password': password,
    'clientToken': clientToken,
    'requestUser': true,
    'agent': {'name': 'Minecraft', 'version': 1},
  });

  /// 刷新令牌；[select] 用于登录后选择角色
  Future<YggdrasilSession> refresh(String accessToken, String clientToken, {GameProfile? select}) => _post('refresh', {
    'accessToken': accessToken,
    'clientToken': clientToken,
    'requestUser': true,
    'selectedProfile': ?select?.toJson(),
  });

  /// 令牌是否有效（204 有效，403 无效）
  Future<bool> validate(String accessToken, String clientToken) async =>
      (await requestJson(
        'POST',
        '$root/authserver/validate',
        json: {'accessToken': accessToken, 'clientToken': clientToken},
      )).status ==
      204;

  Future<YggdrasilSession> _post(String path, Map<String, Object> body) async {
    final r = await requestJson('POST', '$root/authserver/$path', json: body);
    final j = r.map;
    if (!r.ok || j['accessToken'] == null) {
      throw YggdrasilException('${j['errorMessage'] ?? j['error'] ?? '验证服务器返回 HTTP ${r.status}'}');
    }
    return YggdrasilSession(j);
  }
}
