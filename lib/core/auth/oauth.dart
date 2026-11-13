import 'auth.dart';
import 'http_json.dart';

class OAuthToken {
  OAuthToken(Map<String, dynamic> j)
    : accessToken = '${j['access_token']}',
      refreshToken = j['refresh_token'] as String?,
      idToken = j['id_token'] as String?,
      expiresAt = DateTime.now().millisecondsSinceEpoch + ((j['expires_in'] as num?)?.toInt() ?? 3600) * 1000;

  final String accessToken;
  final String? refreshToken;
  final String? idToken;

  /// 毫秒时间戳
  final int expiresAt;
}

/// OAuth 2.0 公共客户端：设备代码流（RFC 8628）与刷新令牌。微软登录与 Yggdrasil Connect 共用
class OAuthClient {
  const OAuthClient({required this.clientId, required this.tokenEndpoint, this.deviceEndpoint});

  final String clientId;
  final String tokenEndpoint;
  final String? deviceEndpoint;

  static String _describe(Map<String, dynamic> j, int status) => '${j['error_description'] ?? j['error'] ?? status}';

  /// 设备代码登录：取得代码后交给 [onCode] 展示，然后轮询直到用户在浏览器中完成授权
  Future<OAuthToken> deviceLogin(
    String scope,
    void Function(DeviceCode) onCode, {
    required bool Function() cancelled,
  }) async {
    final r = await requestJson('POST', deviceEndpoint!, form: {'client_id': clientId, 'scope': scope});
    final dc = r.map;
    if (!r.ok || dc['device_code'] == null) throw Exception('无法开始登录：${_describe(dc, r.status)}');
    final expiresIn = (dc['expires_in'] as num).toInt();
    onCode(
      DeviceCode(
        userCode: '${dc['user_code']}',
        verificationUri: '${dc['verification_uri']}',
        completeUri: dc['verification_uri_complete'] as String?,
      ),
    );

    var interval = Duration(seconds: (dc['interval'] as num?)?.toInt() ?? 5);
    final deadline = DateTime.now().add(Duration(seconds: expiresIn));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(interval);
      if (cancelled()) throw const LoginCancelled();
      final t = await requestJson(
        'POST',
        tokenEndpoint,
        form: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'client_id': clientId,
          'device_code': '${dc['device_code']}',
        },
      );
      switch (t.map['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += const Duration(seconds: 5);
          continue;
        case 'access_denied':
          throw Exception('已拒绝授权');
        case 'expired_token':
          throw Exception('登录超时，请重试');
        case null when t.ok && t.map['access_token'] != null:
          return OAuthToken(t.map);
        default:
          throw Exception('登录失败：${_describe(t.map, t.status)}');
      }
    }
    throw Exception('登录超时，请重试');
  }

  /// 用刷新令牌换新的令牌；刷新令牌已失效时返回 null（网络错误照常抛出）
  Future<OAuthToken?> refresh(String refreshToken, {String? scope}) async {
    final t = await requestJson(
      'POST',
      tokenEndpoint,
      form: {'grant_type': 'refresh_token', 'client_id': clientId, 'refresh_token': refreshToken, 'scope': ?scope},
    );
    if (t.status >= 500) throw Exception('验证服务器暂时不可用（${t.status}），请稍后再试');
    return t.ok && t.map['access_token'] != null ? OAuthToken(t.map) : null;
  }
}
