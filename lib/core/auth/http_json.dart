import 'dart:convert';
import 'dart:io';

import '../../app_info.dart';

final _client = HttpClient()
  ..userAgent = '${AppInfo.name}/${AppInfo.version}'
  ..connectionTimeout = const Duration(seconds: 20);

class JsonResponse {
  JsonResponse(this.status, this.url, this.headers, this.body);

  final int status;

  /// 跟随重定向后的最终地址
  final Uri url;
  final HttpHeaders headers;
  final String body;

  bool get ok => status >= 200 && status < 300;

  /// 响应体中的 JSON 对象；不是对象时为空表
  late final Map<String, dynamic> map = () {
    try {
      final v = jsonDecode(body);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {}
    return <String, dynamic>{};
  }();
}

/// 发送请求：[json] 为 JSON 请求体，[form] 为表单请求体，[bearer] 为 OAuth 访问令牌。GET 自动跟随重定向
Future<JsonResponse> requestJson(
  String method,
  String url, {
  Object? json,
  Map<String, String>? form,
  String? bearer,
}) async {
  var uri = Uri.parse(url);
  final req = await _client.openUrl(method, uri);
  req.headers.set(HttpHeaders.acceptHeader, 'application/json');
  if (bearer != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
  if (form != null) {
    req.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
    req.write(Uri(queryParameters: form).query);
  } else if (json != null) {
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(json));
  }
  final res = await req.close().timeout(const Duration(seconds: 30));
  final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
  for (final r in res.redirects) {
    uri = uri.resolveUri(r.location);
  }
  return JsonResponse(res.statusCode, uri, res.headers, body);
}
