import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pcl_pw/core/ai/agent_root.dart';
import 'package:pcl_pw/core/ai/ai_tools.dart';
import 'package:pcl_pw/core/ai/web_tools.dart';
import 'package:pcl_pw/core/ai/workspace_tools.dart';
import 'package:pcl_pw/core/net_proxy.dart';

void main() {
  group('globToRegExp', () {
    test('* 不跨文件夹，** 跨文件夹', () {
      expect(globToRegExp('*.json').hasMatch('a.json'), isTrue);
      expect(globToRegExp('*.json').hasMatch('config/a.json'), isFalse);
      expect(globToRegExp('**/*.json').hasMatch('a.json'), isTrue);
      expect(globToRegExp('**/*.json').hasMatch('config/sub/a.json'), isTrue);
      expect(globToRegExp('config/*.toml').hasMatch('config/sodium.toml'), isTrue);
      expect(globToRegExp('config/*.toml').hasMatch('config/x/sodium.toml'), isFalse);
      expect(globToRegExp('mod?.jar').hasMatch('mod1.jar'), isTrue);
      expect(globToRegExp('a.b').hasMatch('axb'), isFalse);
    });
  });

  group('replaceExact', () {
    test('唯一匹配时替换', () {
      expect(replaceExact('a = 1\nb = 2', 'b = 2', 'b = 3').text, 'a = 1\nb = 3');
    });
    test('多处匹配时要求 replace_all', () {
      expect(() => replaceExact('x x', 'x', 'y'), throwsA(isA<ToolError>()));
      final r = replaceExact('x x', 'x', 'y', all: true);
      expect(r.text, 'y y');
      expect(r.count, 2);
    });
    test('找不到或相同时报错', () {
      expect(() => replaceExact('abc', 'z', 'y'), throwsA(isA<ToolError>()));
      expect(() => replaceExact('abc', 'a', 'a'), throwsA(isA<ToolError>()));
      expect(() => replaceExact('abc', '', 'a'), throwsA(isA<ToolError>()));
    });
    test('按文件的 CRLF 换行匹配和替换', () {
      final r = replaceExact('a\r\nb\r\nc', 'a\nb', 'x\ny');
      expect(r.text, 'x\r\ny\r\nc');
    });
  });

  test('Windows 保留文件名', () {
    expect(isWindowsReservedName('CON'), isTrue);
    expect(isWindowsReservedName('nul.txt'), isTrue);
    expect(isWindowsReservedName('com3'), isTrue);
    expect(isWindowsReservedName('console.log'), isFalse);
    expect(isWindowsReservedName('com0'), isFalse);
  });

  test('二进制判断', () {
    expect(looksBinary(utf8.encode('hello')), isFalse);
    expect(looksBinary([0x50, 0x4b, 0x03, 0x04, 0x00]), isTrue);
  });

  test('新根目录的 id', () {
    expect(newRootId(r'D:\code\My Project', const []), 'my-project');
    expect(newRootId('/home/a/项目', const []), 'folder');
    expect(newRootId('/x/game', const []), 'game-2');
    expect(newRootId('/x/a', const ['a', 'a-2']), 'a-3');
  });

  group('isBlockedHost', () {
    test('拒绝网址里写明的本机与内网地址', () {
      for (final h in [
        'localhost',
        'a.localhost',
        'printer.local',
        '127.0.0.1',
        '10.0.0.8',
        '172.20.1.1',
        '192.168.1.1',
        '169.254.1.1',
        '0.0.0.0',
        '[::1]',
        'fd00::1',
        'fe80::1',
      ]) {
        expect(isBlockedHost(h), isTrue, reason: h);
      }
    });
    test('普通域名与代理、Tailscale 网段不拦截', () {
      for (final h in ['modrinth.com', 'zh.minecraft.wiki', '198.18.0.5', '100.100.1.1', '8.8.8.8', '172.32.0.1']) {
        expect(isBlockedHost(h), isFalse, reason: h);
      }
    });
  });

  test('解析必应结果（含 ck 跳转链接）', () {
    final target = 'https://modrinth.com/mod/sodium';
    final enc = 'a1${base64Url.encode(utf8.encode(target)).replaceAll('=', '')}';
    final page =
        '''
<ol id="b_results">
  <li class="b_algo"><h2><a href="https://www.bing.com/ck/a?!&&p=1&u=$enc&ntb=1">Sodium - Modrinth</a></h2>
    <div class="b_caption"><p>A modern rendering engine for Minecraft.</p></div></li>
  <li class="b_algo"><h2><a href="https://example.com/x">Example  Title</a></h2><p>Second   result</p></li>
  <li class="b_ad"><h2><a href="https://ad.example">Ad</a></h2></li>
</ol>''';
    final r = parseBing(page);
    expect(r.length, 2);
    expect(r[0].url, target);
    expect(r[0].title, 'Sodium - Modrinth');
    expect(r[0].snippet, 'A modern rendering engine for Minecraft.');
    expect(r[1].title, 'Example Title');
    expect(r[1].snippet, 'Second result');
  });

  test('解析 DuckDuckGo 结果（跳过广告，解出 uddg）', () {
    final page = '''
<div class="result result--ad"><a class="result__a" href="https://ad.example">Ad</a></div>
<div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fminecraft.wiki%2Fw%2FCreeper&amp;rut=x">Creeper</a>
  <a class="result__snippet">A common hostile mob.</a></div>''';
    final r = parseDuckDuckGo(page);
    expect(r.length, 1);
    expect(r[0].url, 'https://minecraft.wiki/w/Creeper');
    expect(r[0].snippet, 'A common hostile mob.');
  });

  test('提取网页正文：去掉脚本与导航，保留标题和段落', () {
    final page = '''
<html><head><title>Creeper – Minecraft Wiki</title><script>var x = 1;</script></head>
<body><nav>菜单 菜单</nav>
<div id="mw-content-text"><h2>行为</h2><p>苦力怕会  靠近玩家并爆炸。</p><ul><li>掉落火药</li></ul></div>
<footer>版权</footer></body></html>''';
    final r = extractPage(page);
    expect(r.title, 'Creeper – Minecraft Wiki');
    expect(r.text, contains('## 行为'));
    expect(r.text, contains('苦力怕会 靠近玩家并爆炸。'));
    expect(r.text, contains('- 掉落火药'));
    expect(r.text, isNot(contains('菜单')));
    expect(r.text, isNot(contains('var x')));
    expect(r.text, isNot(contains('版权')));
  });

  test('解析 Exa 的 MCP 响应（SSE 与普通 JSON）', () {
    const text =
        'Title: Iris issue\nURL: https://github.com/IrisShaders/Iris/issues/3136\nPublished: 2026-10-01\nHighlights:\nIncompatibility between Iris and Sodium.\n\n---\n\nTitle: N/A\nURL: https://example.com/a\nText: Second   result';
    final sse =
        'event: message\ndata: ${jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'result': {
            'content': [
              {'type': 'text', 'text': text},
            ],
          },
        })}\n\n';
    final r = parseMcpResult(sse)!;
    final list = parseExa('${(r['content'] as List).first['text']}');
    expect(list.length, 2);
    expect(list[0].title, 'Iris issue');
    expect(list[0].url, 'https://github.com/IrisShaders/Iris/issues/3136');
    expect(list[0].snippet, 'Incompatibility between Iris and Sodium.');
    expect(list[1].title, 'https://example.com/a');
    expect(list[1].snippet, 'Second result');
    expect(
      parseMcpResult(
        jsonEncode({
          'result': {'content': []},
        }),
      ),
      isNotNull,
    );
    expect(
      () => parseMcpResult(
        jsonEncode({
          'error': {'message': 'rate limited'},
        }),
      ),
      throwsA(isA<ToolError>()),
    );
  });

  test('解析 DeepSeek 搜索结果：优先用 summary，带上日期，跳过没有网址的', () {
    final body = jsonEncode({
      'results': [
        {
          'title': 'Sodium',
          'url': 'https://modrinth.com/mod/sodium',
          'snippet': 's',
          'summary': '  A  rendering mod ',
          'date': '2026-10-01T00:00:00Z',
        },
        {'title': '', 'url': 'https://example.com/a', 'snippet': 'only snippet', 'summary': '', 'date': null},
        {'title': 'no url', 'url': ''},
      ],
    });
    final list = parseDeepseekSearch(body);
    expect(list.length, 2);
    expect(list[0].snippet, '[2026-10-01] A rendering mod');
    expect(list[1].title, 'https://example.com/a');
    expect(list[1].snippet, 'only snippet');
    expect(parseDeepseekSearch(jsonEncode({'results': []})), isEmpty);
    expect(
      parseDeepseekSearch(
        jsonEncode({
          'error': {'message': 'x'},
        }),
      ),
      isEmpty,
    );
  });

  test('DeepSeek 搜索只在模型接口是 DeepSeek 时借用模型的 Key', () {
    expect(deepseekSearchKey('https://api.deepseek.com/v1', () => 'sk-model'), 'sk-model');
    expect(deepseekSearchKey('https://api.deepseek.com', () => 'sk-model'), 'sk-model');
    expect(deepseekSearchKey('https://api.openai.com/v1', () => 'sk-model'), '');
    expect(deepseekSearchKey('https://api.deepseek.com.evil.example/v1', () => 'sk-model'), '');
  });

  group('系统代理解析', () {
    test('Windows：开启时读取地址与例外', () {
      const out = r'''
HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    127.0.0.1:7890
    ProxyOverride    REG_SZ    localhost;127.*;<local>
''';
      final r = parseWindowsProxy(out)!;
      expect(r.http, '127.0.0.1:7890');
      expect(r.https, '127.0.0.1:7890');
      expect(r.bypass, contains('<local>'));
    });
    test('Windows：分协议的写法与关闭状态', () {
      final r = parseWindowsProxy(
        '    ProxyEnable    REG_DWORD    0x1\n    ProxyServer    REG_SZ    http=127.0.0.1:1080;https=127.0.0.1:1081;socks=127.0.0.1:1082\n',
      )!;
      expect(r.http, '127.0.0.1:1080');
      expect(r.https, '127.0.0.1:1081');
      expect(
        parseWindowsProxy('    ProxyEnable    REG_DWORD    0x0\n    ProxyServer    REG_SZ    127.0.0.1:7890\n'),
        isNull,
      );
    });
    test('macOS scutil', () {
      const out = '''
<dictionary> {
  ExceptionsList : <array> {
    0 : 127.0.0.1
    1 : localhost
  }
  HTTPEnable : 1
  HTTPPort : 7890
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 7890
  HTTPSProxy : 127.0.0.1
}''';
      final r = parseScutilProxy(out)!;
      expect(r.https, '127.0.0.1:7890');
      expect(r.bypass, containsAll(['127.0.0.1', 'localhost']));
      expect(parseScutilProxy('<dictionary> {\n  HTTPEnable : 0\n}'), isNull);
    });
  });

  test('本机地址不走代理', () {
    expect(SystemProxy.find(Uri.parse('http://localhost:11434/v1')), 'DIRECT');
    expect(SystemProxy.find(Uri.parse('http://127.0.0.1:8080/')), 'DIRECT');
  }, skip: Platform.environment.containsKey('http_proxy') ? '环境变量里设置了代理' : false);
}
