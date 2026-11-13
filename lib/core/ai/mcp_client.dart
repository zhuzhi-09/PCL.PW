import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../app_info.dart';
import '../net_proxy.dart';
import '../paths.dart';
import '../secure.dart';

// MCP（Model Context Protocol）客户端：让应用内 AI 使用外部 MCP 服务提供的工具。
// 启动器只主动连出去，不监听任何端口。支持两种服务：
//   http：远程或本机的 Streamable HTTP 服务（填网址；Termux 里跑的服务可以填 http://127.0.0.1:端口）
//   jar： 本机 Java 写的服务，启动器用 Java 运行 jar，经标准输入输出通信（stdio）
// 服务返回的工具说明和结果都不可信，只当作数据交给模型。

const mcpProtocolVersion = '2025-06-18';

/// 用户添加的一个 MCP 服务（保存在设置的 aiMcpServers 里；访问令牌单独加密保存）
class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.name,
    required this.type,
    this.url = '',
    this.jar = '',
    this.args = const [],
    this.enabled = true,
    this.trusted = false,
  });

  factory McpServerConfig.fromJson(Map<String, dynamic> j) => McpServerConfig(
    id: '${j['id'] ?? ''}',
    name: '${j['name'] ?? ''}',
    type: j['type'] == 'jar' ? 'jar' : 'http',
    url: '${j['url'] ?? ''}',
    jar: '${j['jar'] ?? ''}',
    args: [for (final a in (j['args'] as List? ?? const [])) '$a'],
    enabled: j['enabled'] != false,
    trusted: j['trusted'] == true,
  );

  /// 小写字母、数字，用于工具名前缀
  final String id;
  final String name;

  /// http 或 jar
  final String type;
  final String url;
  final String jar;
  final List<String> args;
  final bool enabled;

  /// 信任服务对工具的「只读」声明：声明只读的工具不需要确认（会修改内容的仍然要确认）
  final bool trusted;

  bool get isJar => type == 'jar';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    if (!isJar) 'url': url,
    if (isJar) 'jar': jar,
    if (isJar && args.isNotEmpty) 'args': args,
    'enabled': enabled,
    if (trusted) 'trusted': true,
  };

  McpServerConfig copyWith({
    String? name,
    String? url,
    String? jar,
    List<String>? args,
    bool? enabled,
    bool? trusted,
  }) => McpServerConfig(
    id: id,
    name: name ?? this.name,
    type: type,
    url: url ?? this.url,
    jar: jar ?? this.jar,
    args: args ?? this.args,
    enabled: enabled ?? this.enabled,
    trusted: trusted ?? this.trusted,
  );

  /// 配置变化（地址、jar、参数）后要重新连接
  String get signature => jsonEncode([type, url, jar, args, trusted]);
}

/// 默认配置好并打开的服务：Exa 公开的搜索服务（不需要 Key，国内可以直连）。
/// 它的工具都只读，所以信任它的只读声明，用的时候不用确认
const defaultMcpServers = [
  McpServerConfig(id: 'exa', name: 'Exa 搜索', type: 'http', url: 'https://mcp.exa.ai/mcp', trusted: true),
];

final mcpIdPattern = RegExp(r'^[a-z0-9]{1,16}$');

/// 给新服务起一个 id：名称里的字母数字，重复时加序号
String newMcpId(String name, Iterable<String> taken) {
  var base = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (base.isEmpty) base = 'mcp';
  if (base.length > 12) base = base.substring(0, 12);
  final used = taken.toSet();
  var id = base;
  for (var i = 2; used.contains(id); i++) {
    id = '$base$i';
  }
  return id;
}

/// 网址检查：只允许 http / https；http 只允许本机地址（远程服务的令牌不能明文传输）
String? checkMcpUrl(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || !u.hasScheme || u.host.isEmpty) return '网址无效';
  if (u.scheme == 'https') return null;
  if (u.scheme != 'http') return '只支持 http / https';
  return isLoopbackHost(u.host) ? null : '远程服务请使用 https；http 只能连接本机（127.0.0.1 / localhost）';
}

bool isLoopbackHost(String host) {
  final h = host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
  if (h == 'localhost') return true;
  final ip = InternetAddress.tryParse(h);
  return ip != null && ip.isLoopback;
}

/// 访问令牌：每个服务单独加密保存，只会作为 Authorization 头发给这个服务
abstract final class McpSecret {
  static File _file(String id) => File(p.join(Paths.configDir, 'mcp-$id.dat'));

  static String load(String id) {
    try {
      final f = _file(id);
      return f.existsSync() ? utf8.decode(SecureData.unprotect(f.readAsBytesSync())) : '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> save(String id, String token) async {
    final f = _file(id);
    final t = token.trim();
    if (t.isEmpty) {
      if (f.existsSync()) await f.delete();
      return;
    }
    await f.parent.create(recursive: true);
    await f.writeAsBytes(SecureData.protect(Uint8List.fromList(utf8.encode(t))));
  }
}

class McpError implements Exception {
  McpError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 服务提供的一个工具
class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.readOnly = false,
    this.destructive = false,
  });

  factory McpTool.fromJson(Map<String, dynamic> j) {
    final ann = (j['annotations'] as Map?) ?? const {};
    final schema = j['inputSchema'];
    return McpTool(
      name: '${j['name'] ?? ''}',
      description: '${j['description'] ?? j['title'] ?? ''}',
      inputSchema: schema is Map<String, dynamic> && schema['type'] == 'object'
          ? schema
          : const {'type': 'object', 'properties': <String, dynamic>{}},
      readOnly: ann['readOnlyHint'] == true,
      destructive: ann['destructiveHint'] == true,
    );
  }

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  /// 服务自己声明的提示，只用于显示与是否要每次确认，不能据此跳过确认
  final bool readOnly;
  final bool destructive;
}

/// 把 tools/call 的结果转成交给模型的文本
String formatMcpResult(Map<String, dynamic> result, {int maxChars = 20000}) {
  final parts = <String>[];
  for (final c in (result['content'] as List? ?? const []).whereType<Map>()) {
    switch (c['type']) {
      case 'text':
        parts.add('${c['text'] ?? ''}');
      case 'image':
        parts.add('[图片 ${c['mimeType'] ?? ''}，没有显示]');
      case 'audio':
        parts.add('[音频 ${c['mimeType'] ?? ''}，没有播放]');
      case 'resource':
        final r = (c['resource'] as Map?) ?? const {};
        parts.add(r['text'] != null ? '${r['text']}' : '[资源 ${r['uri'] ?? ''}]');
      case 'resource_link':
        parts.add('[链接 ${c['name'] ?? ''} ${c['uri'] ?? ''}]');
    }
  }
  if (parts.isEmpty && result['structuredContent'] != null) parts.add(jsonEncode(result['structuredContent']));
  var text = parts.join('\n').trim();
  if (text.length > maxChars) text = '${text.substring(0, maxChars)}\n……（结果太长，后面 ${text.length - maxChars} 个字符没有显示）';
  return text.isEmpty ? '（没有返回内容）' : text;
}

/// 一条 JSON-RPC 通道
abstract class McpTransport {
  /// 发送请求并等待对应的响应，返回 result
  Future<Map<String, dynamic>> request(String method, Map<String, dynamic> params, {Duration? timeout});

  Future<void> notify(String method, Map<String, dynamic> params);

  Future<void> close();

  /// 出错时附带的诊断信息（例如 jar 的错误输出）
  String get diagnostics => '';
}

Map<String, dynamic> _resultOf(Map<String, dynamic> msg) {
  final err = msg['error'];
  if (err is Map) throw McpError('服务返回错误：${err['message'] ?? err}');
  final r = msg['result'];
  return r is Map<String, dynamic> ? r : <String, dynamic>{};
}

/// Streamable HTTP：每条消息 POST 到同一个地址，响应是 JSON 或 SSE 流
class McpHttpTransport extends McpTransport {
  McpHttpTransport(this.url, {this.token = ''}) {
    _client
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = '${AppInfo.name}/${AppInfo.version}'
      // 本机地址直连；其余跟随系统代理
      ..findProxy = SystemProxy.find;
  }

  final Uri url;
  final String token;
  final _client = HttpClient();
  String? _session;
  var _nextId = 1;

  static const _maxBytes = 8 << 20;

  Future<HttpClientResponse> _post(Map<String, dynamic> msg) async {
    final req = await _client.postUrl(url).timeout(const Duration(seconds: 20));
    req.followRedirects = false;
    req.headers.contentType = ContentType.json;
    req.headers.set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
    req.headers.set('MCP-Protocol-Version', mcpProtocolVersion);
    if (token.isNotEmpty) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (_session != null) req.headers.set('Mcp-Session-Id', _session!);
    req.add(utf8.encode(jsonEncode(msg)));
    final res = await req.close().timeout(const Duration(seconds: 30));
    final sid = res.headers.value('mcp-session-id');
    if (sid != null && sid.isNotEmpty) _session = sid;
    return res;
  }

  static Future<String> _readText(HttpClientResponse res) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(const Duration(seconds: 30))) {
      b.add(chunk);
      if (b.length > 64 * 1024) break;
    }
    return utf8.decode(b.takeBytes(), allowMalformed: true);
  }

  static String _httpError(int status, String body) {
    final hint = switch (status) {
      401 || 403 => '访问被拒绝，检查访问令牌',
      404 => '地址不对，或服务已经关闭了这个会话',
      _ => '',
    };
    final text = body.trim();
    return 'HTTP $status${hint.isEmpty ? '' : '（$hint）'}${text.isEmpty ? '' : '：${text.length > 200 ? text.substring(0, 200) : text}'}';
  }

  @override
  Future<Map<String, dynamic>> request(String method, Map<String, dynamic> params, {Duration? timeout}) async {
    final id = _nextId++;
    Future<Map<String, dynamic>> run() async {
      final res = await _post({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
      if (res.statusCode >= 300) throw McpError(_httpError(res.statusCode, await _readText(res)));
      final type = res.headers.contentType?.mimeType ?? '';
      if (type == 'text/event-stream') return _resultOf(await _readSse(res, id));
      final b = BytesBuilder(copy: false);
      await for (final chunk in res) {
        b.add(chunk);
        if (b.length > _maxBytes) throw McpError('响应太大');
      }
      final msg = jsonDecode(utf8.decode(b.takeBytes(), allowMalformed: true));
      if (msg is! Map<String, dynamic>) throw McpError('响应格式不对');
      return _resultOf(msg);
    }

    try {
      return await run().timeout(timeout ?? const Duration(seconds: 120));
    } on TimeoutException {
      throw McpError('等待服务响应超时');
    } on FormatException {
      throw McpError('服务的响应不是有效的 JSON');
    } on SocketException catch (e) {
      throw McpError('连不上服务：${e.message}');
    } on HttpException catch (e) {
      throw McpError('连接出错：${e.message}');
    }
  }

  /// 读 SSE 流，直到出现 id 对应的响应；服务发来的其他消息（进度、日志）忽略
  Future<Map<String, dynamic>> _readSse(HttpClientResponse res, int id) async {
    var data = StringBuffer();
    var total = 0;
    await for (final line in res.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter())) {
      total += line.length;
      if (total > _maxBytes) throw McpError('响应太大');
      if (line.startsWith('data:')) {
        data.write(line.substring(5).trimLeft());
        continue;
      }
      if (line.isNotEmpty || data.isEmpty) continue;
      // 空行：一个事件结束
      final text = data.toString();
      data = StringBuffer();
      try {
        final msg = jsonDecode(text);
        if (msg is Map<String, dynamic> && msg['id'] == id && (msg.containsKey('result') || msg.containsKey('error'))) {
          return msg;
        }
      } on FormatException {
        // 不是 JSON 的事件忽略
      }
    }
    if (data.isNotEmpty) {
      final msg = jsonDecode(data.toString());
      if (msg is Map<String, dynamic> && msg['id'] == id) return msg;
    }
    throw McpError('服务没有返回响应就断开了');
  }

  @override
  Future<void> notify(String method, Map<String, dynamic> params) async {
    try {
      final res = await _post({'jsonrpc': '2.0', 'method': method, 'params': params});
      await res.drain<void>();
    } catch (_) {
      // 通知失败不影响后续请求
    }
  }

  @override
  Future<void> close() async {
    final sid = _session;
    if (sid != null) {
      try {
        final req = await _client.deleteUrl(url).timeout(const Duration(seconds: 5));
        req.headers.set('Mcp-Session-Id', sid);
        if (token.isNotEmpty) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        await (await req.close().timeout(const Duration(seconds: 5))).drain<void>();
      } catch (_) {}
    }
    _client.close(force: true);
  }
}

/// stdio：每行一条 JSON-RPC 消息。服务进程由调用方启动（桌面上用 Java 运行 jar）
class McpStdioTransport extends McpTransport {
  McpStdioTransport(this._process) {
    _out = _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onLine, onDone: () => _fail('服务进程已经退出'));
    _err = _process.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((
      l,
    ) {
      _stderr.add(l);
      while (_stderr.length > 40) {
        _stderr.removeFirst();
      }
    });
    unawaited(_process.exitCode.then((code) => _fail('服务进程已经退出（退出代码 $code）')));
  }

  final Process _process;
  late final StreamSubscription<String> _out;
  late final StreamSubscription<String> _err;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _stderr = Queue<String>();
  var _nextId = 1;
  String? _closed;

  @override
  String get diagnostics => _stderr.isEmpty ? '' : _stderr.toList().reversed.take(8).toList().reversed.join('\n');

  void _fail(String reason) {
    _closed ??= reason;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(McpError(_withDiagnostics(reason)));
    }
    _pending.clear();
  }

  String _withDiagnostics(String reason) => diagnostics.isEmpty ? reason : '$reason\n$diagnostics';

  void _onLine(String line) {
    final t = line.trim();
    if (!t.startsWith('{')) return;
    Map<String, dynamic> msg;
    try {
      final o = jsonDecode(t);
      if (o is! Map<String, dynamic>) return;
      msg = o;
    } on FormatException {
      return;
    }
    final id = msg['id'];
    if (msg.containsKey('method')) {
      // 服务发来的请求：只回应 ping，其余（例如请求采样）不支持
      if (id != null) {
        _write(
          msg['method'] == 'ping'
              ? {'jsonrpc': '2.0', 'id': id, 'result': <String, dynamic>{}}
              : {
                  'jsonrpc': '2.0',
                  'id': id,
                  'error': {'code': -32601, 'message': 'Pixel World 不支持这个请求'},
                },
        );
      }
      return;
    }
    if (id is int) _pending.remove(id)?.complete(msg);
  }

  void _write(Map<String, dynamic> msg) {
    try {
      _process.stdin.writeln(jsonEncode(msg));
    } catch (_) {}
  }

  @override
  Future<Map<String, dynamic>> request(String method, Map<String, dynamic> params, {Duration? timeout}) async {
    if (_closed != null) throw McpError(_withDiagnostics(_closed!));
    final id = _nextId++;
    final c = _pending[id] = Completer<Map<String, dynamic>>();
    _write({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    try {
      return _resultOf(await c.future.timeout(timeout ?? const Duration(seconds: 120)));
    } on TimeoutException {
      _pending.remove(id);
      throw McpError(_withDiagnostics('等待服务响应超时'));
    }
  }

  @override
  Future<void> notify(String method, Map<String, dynamic> params) async =>
      _write({'jsonrpc': '2.0', 'method': method, 'params': params});

  @override
  Future<void> close() async {
    _closed ??= '已关闭';
    try {
      await _process.stdin.close();
    } catch (_) {}
    // 给服务一点时间自己退出，然后强制结束
    final exited = await _process.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -1);
    if (exited == -1) _process.kill();
    await _out.cancel();
    await _err.cancel();
  }
}

/// 一个已初始化的 MCP 会话
class McpClient {
  McpClient._(this.transport, this.serverName, this.instructions);

  final McpTransport transport;

  /// 服务自报的名称与使用说明（不可信，只作为参考）
  final String serverName;
  final String instructions;

  static Future<McpClient> connect(McpTransport transport) async {
    try {
      final r = await transport.request('initialize', {
        'protocolVersion': mcpProtocolVersion,
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': AppInfo.name, 'version': AppInfo.version},
      }, timeout: const Duration(seconds: 30));
      if (r['capabilities'] is Map && (r['capabilities'] as Map)['tools'] == null) {
        throw McpError('这个服务没有提供工具');
      }
      await transport.notify('notifications/initialized', {});
      final info = (r['serverInfo'] as Map?) ?? const {};
      return McpClient._(transport, '${info['name'] ?? ''}', '${r['instructions'] ?? ''}');
    } catch (_) {
      await transport.close();
      rethrow;
    }
  }

  Future<List<McpTool>> listTools() async {
    final out = <McpTool>[];
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final r = await transport.request('tools/list', {'cursor': ?cursor}, timeout: const Duration(seconds: 30));
      for (final t in (r['tools'] as List? ?? const []).whereType<Map<String, dynamic>>()) {
        final tool = McpTool.fromJson(t);
        if (tool.name.isNotEmpty) out.add(tool);
      }
      cursor = r['nextCursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
    return out;
  }

  /// 调用工具，返回给模型的文本；工具报告失败时抛出 [McpError]
  Future<String> callTool(String name, Map<String, dynamic> args) async {
    final r = await transport.request('tools/call', {'name': name, 'arguments': args});
    final text = formatMcpResult(r);
    if (r['isError'] == true) throw McpError(text);
    return text;
  }

  Future<void> close() => transport.close();
}
