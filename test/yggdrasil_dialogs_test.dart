import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pcl_pw/core/accounts.dart';
import 'package:pcl_pw/core/auth/auth.dart';
import 'package:pcl_pw/core/auth/yggdrasil.dart';
import 'package:pcl_pw/core/auth/yggdrasil_connect.dart';
import 'package:pcl_pw/widgets/launch_dialogs.dart';
import 'package:pcl_pw/widgets/yggdrasil_login_dialog.dart';

Future<BuildContext> _host(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (c) {
          ctx = c;
          return const Scaffold();
        },
      ),
    ),
  );
  return ctx;
}

/// 测试中不真正登录：记下执行的命令，然后失败
final _commands = <LoginCommand>[];
Future<Account> _fakeRun(LoginCommand c) async {
  _commands.add(c);
  throw Exception('测试中不登录');
}

Iterable<ConnectLogin> get _oauthRuns => _commands.whereType<ConnectLogin>();

/// 打开外置登录；[type] 为直接输入的地址，为空时从下拉列表选择 littleskin.cn；然后点「下一步」
Future<void> _enterAddress(WidgetTester tester, {String? type}) async {
  _commands.clear();
  showYggdrasilLogin(await _host(tester), run: _fakeRun);
  await tester.pumpAndSettle();
  expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '下一步')).onPressed, isNull);
  if (type != null) {
    await tester.enterText(find.byType(TextField), type);
  } else {
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'littleskin.cn'));
  }
  await tester.pumpAndSettle();
  await tester.tap(find.text('下一步'));
  await tester.pumpAndSettle();
}

Finder get _loginButton => find.widgetWithText(FilledButton, '登录');

void main() {
  testWidgets('外置登录：从下拉列表选择内置站点，默认显示 OAuth，点开始后才登录，可以和账户密码来回切换', (tester) async {
    await _enterAddress(tester);
    expect(find.text('littleskin.cn'), findsOneWidget);
    expect(_commands, isEmpty); // 不会自动开始
    await tester.tap(find.text('开始 OAuth 登录'));
    await tester.pumpAndSettle();
    expect(_oauthRuns.single.site, 'littleskin.cn');
    expect(find.text('测试中不登录'), findsOneWidget); // OAuth 面板显示失败原因
    expect(_loginButton, findsNothing);

    await tester.tap(find.text('账户密码'));
    await tester.pumpAndSettle();
    expect(find.text('验证服务器：littleskin.cn'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '账户'), 'bob@example.com');
    await tester.enterText(find.widgetWithText(TextField, '密码'), 'pw');
    await tester.tap(_loginButton);
    await tester.pumpAndSettle();
    final password = _commands.whereType<YggdrasilLogin>().single;
    expect((password.server, password.username), ('littleskin.cn', 'bob@example.com'));

    // 切回 OAuth：之前的状态还在，不会重新开始
    await tester.tap(find.text('OAuth 授权'));
    await tester.pumpAndSettle();
    expect(_oauthRuns, hasLength(1));
    expect(_loginButton, findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(_oauthRuns, hasLength(2));

    // 再切到账户密码，填写的内容还在
    await tester.tap(find.text('账户密码'));
    await tester.pumpAndSettle();
    expect(find.text('bob@example.com'), findsOneWidget);
  });

  testWidgets('外置登录：手动输入内置站点的地址也支持 OAuth', (tester) async {
    await _enterAddress(tester, type: 'https://LittleSkin.cn/api/yggdrasil');
    expect(find.byType(SegmentedButton<bool>), findsOneWidget);
    expect(find.text('开始 OAuth 登录'), findsOneWidget);
    // 没点开始就切到账户密码，不会发起 OAuth
    await tester.tap(find.text('账户密码'));
    await tester.pumpAndSettle();
    expect(_commands, isEmpty);
    await tester.tap(find.text('OAuth 授权'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始 OAuth 登录'));
    await tester.pumpAndSettle();
    expect(_oauthRuns.single.site, 'littleskin.cn');
  });

  testWidgets('外置登录：其他地址只能账户密码登录', (tester) async {
    await _enterAddress(tester, type: 'example.com');
    expect(find.byType(SegmentedButton<bool>), findsNothing);
    expect(find.textContaining('OAuth'), findsNothing);
    expect(_commands, isEmpty);
    expect(find.text('验证服务器：example.com'), findsOneWidget);
    expect(_loginButton, findsOneWidget);
    expect(find.textContaining('明文'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('外置登录：http:// 地址提示明文传输', (tester) async {
    await _enterAddress(tester, type: 'http://example.com');
    expect(find.textContaining('明文'), findsOneWidget);
  });

  testWidgets('启动时重新输入密码', (tester) async {
    final ctx = await _host(tester);
    final acc = Account(
      id: '1',
      type: AccountType.yggdrasil,
      name: 'Bob',
      uuid: 'u',
      accessToken: 't',
      server: 'https://example.com/api/yggdrasil',
      serverName: 'Example',
      login: 'bob@example.com',
    );
    final result = DialogLaunchPrompts(ctx).askPassword(acc);
    await tester.pumpAndSettle();
    expect(find.text('重新登录 Example'), findsOneWidget);
    expect(find.textContaining('bob@example.com'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'secret');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(await result, 'secret');
  });
}
