// 测试用的最小 MCP stdio 服务：每行一条 JSON-RPC 消息
import 'dart:convert';
import 'dart:io';

void main() {
  stderr.writeln('fake server started');
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final msg = jsonDecode(line) as Map<String, dynamic>;
    final id = msg['id'];
    if (id == null) return;
    Object? result;
    switch (msg['method']) {
      case 'initialize':
        result = {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'fake-stdio'},
        };
      case 'tools/list':
        result = {
          'tools': [
            {
              'name': 'echo',
              'description': 'Echo text',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'text': {'type': 'string'},
                },
              },
            },
          ],
        };
      case 'tools/call':
        final args = (msg['params'] as Map)['arguments'] as Map;
        if (args['text'] == 'exit') exit(3);
        // 先发一条服务端通知，客户端应该忽略
        stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/message', 'params': {}}));
        result = {
          'content': [
            {'type': 'text', 'text': 'echo: ${args['text']}'},
          ],
        };
    }
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  });
}
