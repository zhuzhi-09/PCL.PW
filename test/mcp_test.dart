import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pcl_pw/core/ai/ai_client.dart';
import 'package:pcl_pw/core/ai/ai_tools.dart';
import 'package:pcl_pw/core/ai/mcp_client.dart';
import 'package:pcl_pw/core/ai/mcp_hub.dart';

/// 本机的假 MCP 服务（Streamable HTTP）：initialize 用 JSON 响应，tools/call 用 SSE 响应
Future<(HttpServer, List<String>)> _fakeHttpServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final seen = <String>[];
  server.listen((req) async {
    if (req.headers.value('authorization') != 'Bearer secret') {
      req.response.statusCode = 401;
      await req.response.close();
      return;
    }
    if (req.method == 'DELETE') {
      seen.add('DELETE ${req.headers.value('mcp-session-id')}');
      await req.response.close();
      return;
    }
    final msg = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
    final method = '${msg['method']}';
    seen.add('$method ${req.headers.value('mcp-session-id') ?? '-'}');
    final id = msg['id'];
    if (id == null) {
      req.response.statusCode = 202;
      await req.response.close();
      return;
    }
    Map<String, dynamic> reply(Object result) => {'jsonrpc': '2.0', 'id': id, 'result': result};
    switch (method) {
      case 'initialize':
        req.response.headers
          ..contentType = ContentType.json
          ..set('Mcp-Session-Id', 'sess-1');
        req.response.write(
          jsonEncode(
            reply({
              'protocolVersion': mcpProtocolVersion,
              'capabilities': {'tools': {}},
              'serverInfo': {'name': 'fake-http'},
              'instructions': 'Use carefully.',
            }),
          ),
        );
      case 'tools/list':
        final cursor = (msg['params'] as Map)['cursor'];
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(
            reply(
              cursor == null
                  ? {
                      'tools': [
                        {
                          'name': 'search',
                          'description': 'Search things',
                          'annotations': {'readOnlyHint': true},
                        },
                      ],
                      'nextCursor': 'p2',
                    }
                  : {
                      'tools': [
                        {
                          'name': 'delete.all',
                          'inputSchema': {'type': 'object', 'properties': {}},
                          'annotations': {'destructiveHint': true},
                        },
                      ],
                    },
            ),
          ),
        );
      case 'tools/call':
        final name = (msg['params'] as Map)['name'];
        req.response.headers.contentType = ContentType('text', 'event-stream');
        // 先来一条进度通知，再来结果
        req.response.write('event: message\ndata: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}\n\n');
        final result = name == 'boom'
            ? {
                'isError': true,
                'content': [
                  {'type': 'text', 'text': 'boom failed'},
                ],
              }
            : {
                'content': [
                  {'type': 'text', 'text': 'found 3'},
                  {'type': 'image', 'mimeType': 'image/png', 'data': 'AAAA'},
                ],
              };
        req.response.write('event: message\ndata: ${jsonEncode(reply(result))}\n\n');
    }
    await req.response.close();
  });
  return (server, seen);
}

HubTool _tool(ToolKind kind, {Future<String> Function()? run}) => HubTool(
  server: BuiltinMcpServer('t', '测试服务', () => const []),
  spec: const AiTool('t_op', 'op', {'type': 'object'}),
  kind: kind,
  label: '测试操作',
  prepare: (_) async => ToolPlan('做一件事', run ?? () async => 'ok'),
);

void main() {
  group('MCP HTTP', () {
    test('初始化、分页列出工具、SSE 结果、会话 id 与令牌', () async {
      final (server, seen) = await _fakeHttpServer();
      try {
        final url = Uri.parse('http://127.0.0.1:${server.port}/mcp');
        final client = await McpClient.connect(McpHttpTransport(url, token: 'secret'));
        expect(client.serverName, 'fake-http');
        expect(client.instructions, 'Use carefully.');

        final tools = await client.listTools();
        expect(tools.map((t) => t.name), ['search', 'delete.all']);
        expect(tools[0].readOnly, isTrue);
        expect(tools[0].inputSchema['type'], 'object');
        expect(tools[1].destructive, isTrue);

        expect(await client.callTool('search', {'q': 'x'}), 'found 3\n[图片 image/png，没有显示]');
        await expectLater(client.callTool('boom', {}), throwsA(isA<McpError>()));
        await client.close();

        // 初始化之后的请求都带上服务给的会话 id，关闭时结束会话
        expect(seen.first, 'initialize -');
        expect(seen.skip(1).where((s) => !s.startsWith('DELETE')), everyElement(endsWith('sess-1')));
        expect(seen.last, 'DELETE sess-1');
      } finally {
        await server.close(force: true);
      }
    });

    test('令牌不对时给出可读的错误', () async {
      final (server, _) = await _fakeHttpServer();
      try {
        final url = Uri.parse('http://127.0.0.1:${server.port}/mcp');
        await expectLater(
          McpClient.connect(McpHttpTransport(url, token: 'wrong')),
          throwsA(isA<McpError>().having((e) => e.message, 'message', contains('401'))),
        );
      } finally {
        await server.close(force: true);
      }
    });
  });

  test('MCP stdio：请求与响应按 id 对应，忽略服务端通知，进程退出时报错', () async {
    final proc = await Process.start('dart', ['test/fixtures/mcp_stdio_server.dart'], runInShell: Platform.isWindows);
    final client = await McpClient.connect(McpStdioTransport(proc));
    expect(client.serverName, 'fake-stdio');
    expect((await client.listTools()).single.name, 'echo');
    expect(await client.callTool('echo', {'text': 'hi'}), 'echo: hi');
    await expectLater(
      client.callTool('echo', {'text': 'exit'}),
      throwsA(isA<McpError>().having((e) => e.message, 'message', contains('退出'))),
    );
    await client.close();
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('服务权限与确认', () {
    test('只读服务直接拒绝会修改内容的操作，不询问用户', () async {
      var asked = false;
      var ran = false;
      final out = await runHubTool(
        _tool(ToolKind.write, run: () async => '${ran = true}'),
        {},
        policy: McpPolicy.readOnly,
        approve: (_, _) async => asked = true,
      );
      expect(out.status, 'denied');
      expect(out.content, contains('只读'));
      expect(asked, isFalse);
      expect(ran, isFalse);
    });

    test('只读服务里的只读操作照常执行', () async {
      final out = await runHubTool(_tool(ToolKind.read), {}, policy: McpPolicy.readOnly, approve: (_, _) async => true);
      expect(out.status, 'done');
      expect(out.content, 'ok');
    });

    test('用户拒绝、无法询问与执行出错', () async {
      expect(
        (await runHubTool(_tool(ToolKind.danger), {}, policy: McpPolicy.ask, approve: (_, _) async => false)).status,
        'denied',
      );
      final game = await runHubTool(_tool(ToolKind.write), {}, policy: McpPolicy.ask, approve: (_, _) async => null);
      expect(game.status, 'denied');
      expect(game.content, contains('游戏内'));
      final logged = <String>[];
      final ok = await runHubTool(
        _tool(ToolKind.write),
        {},
        policy: McpPolicy.ask,
        approve: (_, _) async => true,
        log: (title, _) => logged.add(title),
      );
      expect(ok.status, 'done');
      expect(logged, ['做一件事']);
      final err = await runHubTool(
        _tool(ToolKind.read, run: () async => throw StateError('x')),
        {},
        policy: McpPolicy.ask,
        approve: (_, _) async => true,
      );
      expect(err.status, 'error');
    });
  });

  test('外部服务：默认不相信只读声明，设为信任后只读工具按查看类操作处理', () async {
    final (server, _) = await _fakeHttpServer();
    try {
      final url = 'http://127.0.0.1:${server.port}/mcp';
      Future<McpTransport> open(McpServerConfig c) async => McpHttpTransport(Uri.parse(c.url), token: 'secret');
      final config = McpServerConfig(id: 'fake', name: '假服务', type: 'http', url: url);

      final plain = ExternalMcpServer.withOpener(config, open);
      final kinds = {for (final t in await plain.tools()) t.name: t.kind};
      expect(kinds, {'mcp_fake_search': ToolKind.write, 'mcp_fake_delete_all': ToolKind.danger});
      expect(plain.toolCount, 2);
      await plain.close();

      // 信任后是另一份配置，会重新连接
      final trustedConfig = config.copyWith(trusted: true);
      expect(trustedConfig.signature, isNot(config.signature));
      final trusted = ExternalMcpServer.withOpener(trustedConfig, open);
      final tools = await trusted.tools();
      expect(
        {for (final t in tools) t.name: t.kind},
        {'mcp_fake_search': ToolKind.read, 'mcp_fake_delete_all': ToolKind.danger},
      );
      // 调用结果带上「来自外部服务」的提示
      final out = await (await tools.first.prepare({'q': 'x'})).run();
      expect(out, contains('外部 MCP 服务'));
      expect(out, contains('found 3'));
      await trusted.close();
    } finally {
      await server.close(force: true);
    }
  });

  test('连不上时记下原因', () async {
    final s = ExternalMcpServer.withOpener(
      const McpServerConfig(id: 'down', name: '没开的服务', type: 'http', url: 'http://127.0.0.1:1/mcp'),
      (c) async => McpHttpTransport(Uri.parse(c.url)),
    );
    await expectLater(s.tools(), throwsA(isA<McpError>()));
    expect(s.error, contains('连不上'));
  });

  test('默认配置好 Exa，并信任它的只读声明', () {
    final exa = defaultMcpServers.single;
    expect(exa.url, 'https://mcp.exa.ai/mcp');
    expect(exa.enabled, isTrue);
    expect(exa.trusted, isTrue);
    expect(checkMcpUrl(exa.url), isNull);
    final back = McpServerConfig.fromJson(exa.toJson());
    expect(back.trusted, isTrue);
    expect(back.signature, exa.signature);
  });

  test('工具名、网址检查与结果格式', () {
    expect(mcpToolName('gh', 'list.issues'), 'mcp_gh_list_issues');
    expect(mcpToolName('gh', 'x' * 100).length, 64);
    expect(checkMcpUrl('https://example.com/mcp'), isNull);
    expect(checkMcpUrl('http://127.0.0.1:3000/mcp'), isNull);
    expect(checkMcpUrl('http://localhost:3000/mcp'), isNull);
    expect(checkMcpUrl('http://example.com/mcp'), isNotNull);
    expect(checkMcpUrl('ftp://example.com'), isNotNull);
    expect(newMcpId('GitHub MCP', ['githubmcp']), 'githubmcp2');
    expect(newMcpId('文件', const []), 'mcp');
    expect(
      formatMcpResult({
        'structuredContent': {'a': 1},
      }),
      '{"a":1}',
    );
    expect(formatMcpResult({'content': []}), '（没有返回内容）');
    expect(McpTool.fromJson({'name': 'x', 'inputSchema': 'bad'}).inputSchema['type'], 'object');
  });
}
