// 手动运行的联网测试：外置登录（LittleSkin 的 Yggdrasil Connect 服务发现与设备代码、authlib-injector 下载与参数）。
//   PW_TEST_YGGDRASIL=1 flutter test test/manual/third_party_login_manual_test.dart
// 加上 PW_TEST_LITTLESKIN_WAIT=1 时会等你在浏览器里完成授权，并打印得到的角色（不打印令牌）
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pcl_pw/core/auth/auth.dart';
import 'package:pcl_pw/core/auth/authlib_injector.dart';
import 'package:pcl_pw/core/auth/yggdrasil_api.dart';
import 'package:pcl_pw/core/auth/yggdrasil_connect.dart';
import 'package:pcl_pw/core/download.dart';
import 'package:pcl_pw/core/paths.dart';

void main() {
  final on = Platform.environment['PW_TEST_YGGDRASIL'] == '1';
  final wait = Platform.environment['PW_TEST_LITTLESKIN_WAIT'] == '1';

  test('LittleSkin：ALI 与 Yggdrasil Connect 服务发现', () async {
    final s = await YggdrasilServer.resolve('littleskin.cn');
    print('API 根地址 ${s.root}，名称 ${s.name}，OpenID 配置 ${s.openIdConfigurationUrl}');
    expect(s.root, 'https://littleskin.cn/api/yggdrasil');
    expect(s.openIdConfigurationUrl, isNotNull);
  }, skip: !on);

  test(
    'LittleSkin：设备代码登录（client_id ${YggdrasilConnect.builtInClientIds['littleskin.cn']}）',
    () async {
      final code = Completer<DeviceCode>();
      final login = ConnectLogin('littleskin.cn', code.complete);
      final result = login.execute();
      final c = await Future.any([code.future, result.then<DeviceCode>((_) => throw StateError('没有返回代码'))]);
      print('用户代码 ${c.userCode}，授权页面 ${c.completeUri ?? c.verificationUri}');
      if (!wait) {
        login.cancel();
        await expectLater(result, throwsA(isA<LoginCancelled>()));
        return;
      }
      final acc = await result;
      print('已授权：${acc.name}（${acc.uuid}），${acc.typeLabel}，刷新令牌 ${acc.refreshToken != null ? '有' : '无'}');
    },
    skip: !on,
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test('authlib-injector：下载、校验并生成参数', () async {
    Paths.appData = Directory.systemTemp.createTempSync('pw_authlib_').path;
    final args = await AuthlibInjector(Downloader(useMirror: false, concurrency: 1))
        .jvmArgs('https://littleskin.cn/api/yggdrasil');
    print(args.map((a) => a.length > 120 ? '${a.substring(0, 120)}…' : a).join('\n'));
    final jar = RegExp(r'^-javaagent:(.+)=https://littleskin\.cn/api/yggdrasil$').firstMatch(args[0])!.group(1)!;
    expect(File(jar).lengthSync(), greaterThan(100000));
    final prefetched = utf8.decode(base64Decode(args[1].substring(args[1].indexOf('=') + 1)));
    expect(jsonDecode(prefetched)['meta']['serverName'], 'LittleSkin');
  }, skip: !on);
}
