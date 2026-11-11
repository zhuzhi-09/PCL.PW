import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pcl_pw/core/accounts.dart';
import 'package:pcl_pw/core/auth/auth.dart';
import 'package:pcl_pw/core/auth/authlib_injector.dart';
import 'package:pcl_pw/core/auth/yggdrasil.dart';
import 'package:pcl_pw/core/auth/yggdrasil_api.dart';
import 'package:pcl_pw/core/auth/yggdrasil_connect.dart';
import 'package:pcl_pw/core/download.dart';

const _profiles = [
  {'id': '11111111111111111111111111111111', 'name': 'Alice'},
  {'id': '22222222222222222222222222222222', 'name': 'Bob'},
];

/// 最简的 Yggdrasil 验证服务器：首页用相对地址的 ALI 指向 /api/yggdrasil/，账户（密码 pw）有两个角色
class _MockServer {
  late final HttpServer _server;
  String get home => 'http://127.0.0.1:${_server.port}';
  String get root => '$home/api/yggdrasil';

  /// validate 的结果
  var tokenValid = true;

  /// refresh 接受的令牌（登录得到的令牌会加进来）
  final refreshable = <String>{};
  final paths = <String>[];
  var _seq = 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final text = await utf8.decodeStream(req);
      final j = text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
      paths.add(req.uri.path);
      final res = req.response..headers.contentType = ContentType.json;
      void forbidden(String msg) => res
        ..statusCode = 403
        ..write(jsonEncode({'error': 'ForbiddenOperationException', 'errorMessage': msg}));
      String issue() {
        final t = 't${++_seq}';
        refreshable.add(t);
        return t;
      }

      switch (req.uri.path) {
        case '/':
          res.headers.set('X-Authlib-Injector-API-Location', '/api/yggdrasil/');
          res.write('{}');
        case '/api/yggdrasil' || '/api/yggdrasil/':
          res.write(
            jsonEncode({
              'meta': {'serverName': 'Mock'},
              'skinDomains': <String>[],
            }),
          );
        case '/api/yggdrasil/authserver/authenticate':
          if (j['password'] != 'pw') {
            forbidden('密码错误');
            break;
          }
          res.write(
            jsonEncode({'accessToken': issue(), 'clientToken': j['clientToken'], 'availableProfiles': _profiles}),
          );
        case '/api/yggdrasil/authserver/refresh':
          if (!refreshable.remove(j['accessToken'])) {
            forbidden('令牌无效');
            break;
          }
          res.write(
            jsonEncode({
              'accessToken': issue(),
              'clientToken': j['clientToken'],
              'selectedProfile': j['selectedProfile'] ?? _profiles[1],
            }),
          );
        case '/api/yggdrasil/authserver/validate':
          res.statusCode = tokenValid ? 204 : 403;
        default:
          res.statusCode = 404;
      }
      await res.close();
    });
  }

  Future<void> close() => _server.close(force: true);
}

class _Prompts implements AuthPrompts {
  _Prompts(this.password);

  final String? password;
  var asked = 0;

  @override
  Future<String?> askPassword(Account acc) async {
    asked++;
    return password;
  }
}

/// 不下载 jar 的 authlib-injector，用来测试账户验证与参数的组合
class _Injector extends AuthlibInjector {
  _Injector() : super(Downloader(useMirror: false, concurrency: 1));

  @override
  Future<List<String>> jvmArgs(String apiRoot) async => ['-javaagent:authlib-injector.jar=$apiRoot'];
}

String _jwt(Map<String, Object> claims) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'RS256', 'typ': 'JWT'})}.${part(claims)}.sig';
}

void main() {
  late _MockServer mock;
  setUp(() async {
    mock = _MockServer();
    await mock.start();
  });
  tearDown(() => mock.close());

  Account account(String token) => Account(
    id: 'x',
    type: AccountType.yggdrasil,
    name: 'Bob',
    uuid: _profiles[1]['id']!,
    accessToken: token,
    clientToken: 'c',
    server: mock.root,
    serverName: 'Mock',
    login: 'bob@example.com',
  );

  group('YggdrasilServer', () {
    test('按 ALI 响应头（相对地址）找到 API 根地址并读取元数据', () async {
      final s = await YggdrasilServer.resolve(mock.home);
      expect(s.root, mock.root);
      expect(s.name, 'Mock');
      expect(s.openIdConfigurationUrl, isNull);
    });

    test('直接输入 API 地址也可以', () async {
      expect((await YggdrasilServer.resolve('${mock.root}/')).root, mock.root);
    });

    test('不是验证服务器时报错', () async {
      await expectLater(YggdrasilServer.resolve('${mock.home}/nothing'), throwsA(isA<Exception>()));
    });
  });

  group('YggdrasilLogin', () {
    test('多个角色时让用户选择，再用所选角色刷新令牌', () async {
      List<String>? offered;
      final acc = await YggdrasilLogin(
        server: mock.home,
        username: 'bob@example.com',
        password: 'pw',
        chooseProfile: (list) async {
          offered = [for (final p in list) p.name];
          return list[1];
        },
      ).execute();
      expect(offered, ['Alice', 'Bob']);
      expect(acc.type, AccountType.yggdrasil);
      expect((acc.name, acc.uuid), ('Bob', _profiles[1]['id']));
      expect((acc.server, acc.serverName, acc.login), (mock.root, 'Mock', 'bob@example.com'));
      expect(acc.accessToken, 't2'); // 刷新后的令牌
      expect(
        mock.paths,
        containsAllInOrder(['/api/yggdrasil/authserver/authenticate', '/api/yggdrasil/authserver/refresh']),
      );
    });

    test('取消选择角色', () async {
      final login = YggdrasilLogin(server: mock.home, username: 'u', password: 'pw', chooseProfile: (_) async => null);
      await expectLater(login.execute(), throwsA(isA<LoginCancelled>()));
    });

    test('密码错误时显示服务器给的说明', () async {
      final login = YggdrasilLogin(server: mock.home, username: 'u', password: 'bad', chooseProfile: (_) async => null);
      await expectLater(login.execute(), throwsA(predicate((e) => '$e' == '密码错误')));
    });
  });

  group('YggdrasilAuth', () {
    test('令牌有效：直接启动，并带上 authlib-injector 参数', () async {
      final acc = account('t0');
      final prompts = _Prompts(null);
      final s = await YggdrasilAuth(_Injector()).prepare(acc, prompts);
      expect(identical(s.account, acc), isTrue);
      expect(s.jvmArgs, ['-javaagent:authlib-injector.jar=${mock.root}']);
      expect(prompts.asked, 0);
    });

    test('令牌失效：刷新', () async {
      mock
        ..tokenValid = false
        ..refreshable.add('old');
      final s = await YggdrasilAuth(_Injector()).prepare(account('old'), _Prompts(null));
      expect(s.account.accessToken, 't1');
      expect(s.account.id, 'x');
    });

    test('刷新也失败：请用户输入密码，重新登录并选回原来的角色', () async {
      mock.tokenValid = false;
      final prompts = _Prompts('pw');
      final s = await YggdrasilAuth(_Injector()).prepare(account('old'), prompts);
      expect(prompts.asked, 1);
      expect((s.account.uuid, s.account.accessToken), (_profiles[1]['id'], 't2'));
    });

    test('取消输入密码：取消启动', () async {
      mock.tokenValid = false;
      await expectLater(
        YggdrasilAuth(_Injector()).prepare(account('old'), _Prompts(null)),
        throwsA(isA<LoginCancelled>()),
      );
    });
  });

  group('Yggdrasil Connect', () {
    final now = DateTime.utc(2026, 11, 11);
    final iat = now.millisecondsSinceEpoch ~/ 1000;
    Map<String, Object> claims({Object aud = '/* ur littleskin cilent id */', int? exp}) => {
      'iss': 'https://open.littleskin.cn',
      'aud': aud,
      'sub': '1',
      'iat': iat,
      'exp': exp ?? iat + 3600,
      'selectedProfile': {'id': 'f702c5d39d5c457f80c691c664757092', 'name': 'SSSSSteven'},
    };
    GameProfile? check(Map<String, Object> c) =>
        idTokenProfile(_jwt(c), issuer: 'https://open.littleskin.cn', clientId: '/* ur littleskin cilent id */', now: now);

    test('从 ID 令牌取出所选角色', () {
      final p = check(claims())!;
      expect((p.id, p.name), ('f702c5d39d5c457f80c691c664757092', 'SSSSSteven'));
      expect(check(claims(aud: ['other', '/* ur littleskin cilent id */']))?.name, 'SSSSSteven');
    });

    test('受众或有效期不符时拒绝', () {
      expect(() => check(claims(aud: 'other')), throwsException);
      expect(() => check(claims(exp: iat - 3600)), throwsException);
    });

    test('按域名判断填写的地址是不是内置站点（不联网）', () {
      for (final a in ['littleskin.cn', ' LittleSkin.cn ', 'https://littleskin.cn', 'littleskin.cn/api/yggdrasil']) {
        expect(YggdrasilConnect.builtInSite(a), 'littleskin.cn', reason: a);
      }
      for (final a in ['example.com', 'mskin.littleskin.cn', 'notlittleskin.cn', '']) {
        expect(YggdrasilConnect.builtInSite(a), isNull, reason: a);
      }
    });

    test('内置站点按 API 地址的域名找 client_id', () {
      expect(YggdrasilConnect.clientIdFor('https://littleskin.cn/api/yggdrasil'), '/* ur littleskin cilent id */');
      expect(YggdrasilConnect.clientIdFor('https://example.com/api/yggdrasil'), isNull);
    });
  });

  test('账户的外置登录字段可以保存和读取，旧格式照常读取', () {
    final a = Account.fromJson(account('t').toJson());
    expect(
      (a.type, a.server, a.serverName, a.login, a.clientToken),
      (AccountType.yggdrasil, mock.root, 'Mock', 'bob@example.com', 'c'),
    );
    expect(a.typeLabel, '外置登录 · Mock');
    final old = Account.fromJson({'id': '1', 'type': 'microsoft', 'name': 'n', 'uuid': 'u', 'accessToken': 'a'});
    expect((old.type, old.server), (AccountType.microsoft, null));
  });

  test('BMCLAPI 下载源包含 authlib-injector 镜像', () {
    expect(
      Downloader(useMirror: true, concurrency: 1).mirror(AuthlibInjector.latestUrl),
      'https://bmclapi2.bangbang93.com/mirrors/authlib-injector/artifact/latest.json',
    );
  });
}
