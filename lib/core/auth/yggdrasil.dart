import 'dart:async';
import 'dart:io';

import '../accounts.dart';
import 'auth.dart';
import 'authlib_injector.dart';
import 'yggdrasil_api.dart';

/// 登录结果没有选定角色时，选一个角色并用它刷新令牌（authlib-injector 启动器规范「添加账户」）
Future<YggdrasilSession> _bindProfile(YggdrasilClient c, YggdrasilSession s, ProfileChooser choose) async {
  if (s.selected != null) return s;
  if (s.available.isEmpty) throw Exception('该账户还没有角色，请先到皮肤站创建角色');
  final pick = s.available.length == 1 ? s.available.single : await choose(s.available);
  if (pick == null) throw const LoginCancelled();
  final r = await c.refresh(s.accessToken, s.clientToken, select: pick);
  if (r.selected == null) throw const YggdrasilException('验证服务器没有返回所选角色');
  return r;
}

/// 外置登录（Yggdrasil API）：在验证服务器上用账户和密码登录。只保存令牌，不保存密码
class YggdrasilLogin implements LoginCommand {
  YggdrasilLogin({required this.server, required this.username, required this.password, required this.chooseProfile});

  /// 用户输入的验证服务器地址
  final String server;
  final String username;
  final String password;
  final ProfileChooser chooseProfile;
  bool _cancelled = false;

  @override
  void cancel() => _cancelled = true;

  @override
  Future<Account> execute() async {
    final s = await YggdrasilServer.resolve(server);
    final c = YggdrasilClient(s.root);
    final session = await _bindProfile(c, await c.authenticate(username, password, newId()), chooseProfile);
    if (_cancelled) throw const LoginCancelled();
    final profile = session.selected!;
    return Account(
      id: newId(),
      type: AccountType.yggdrasil,
      name: profile.name,
      uuid: profile.id,
      accessToken: session.accessToken,
      clientToken: session.clientToken,
      server: s.root,
      serverName: s.name,
      login: username,
    );
  }
}

/// Yggdrasil API 账户启动前的处理（规范「启动时的账户验证」）：令牌有效直接用，无效先刷新，
/// 刷新失败再请用户输入密码重新登录；同时准备 authlib-injector
class YggdrasilAuth implements AccountAuth {
  const YggdrasilAuth(this.injector);

  final AuthlibInjector injector;

  @override
  Future<AuthSession> prepare(Account acc, AuthPrompts prompts) =>
      injector.inject(_validate(acc, prompts), acc.server!);

  Future<Account> _validate(Account acc, AuthPrompts prompts) async {
    final c = YggdrasilClient(acc.server!);
    final clientToken = acc.clientToken ?? '';
    try {
      if (await c.validate(acc.accessToken, clientToken)) return acc;
      return _update(acc, await c.refresh(acc.accessToken, clientToken));
    } on YggdrasilException {
      // 刷新失败：需要重新输入密码
    } on IOException {
      return acc; // 连不上验证服务器时照常启动（单人游戏不受影响）
    } on TimeoutException {
      return acc;
    }
    final password = await prompts.askPassword(acc);
    if (password == null) throw const LoginCancelled();
    final gone = Exception('角色 ${acc.name} 已不在该账户下，请重新添加账户');
    final s = await _bindProfile(
      c,
      await c.authenticate(acc.login ?? '', password, clientToken),
      (list) async => list.firstWhere((p) => p.id == acc.uuid, orElse: () => throw gone),
    );
    if (s.selected!.id != acc.uuid) throw gone;
    return _update(acc, s);
  }

  static Account _update(Account acc, YggdrasilSession s) =>
      acc.copyWith(name: s.selected?.name, accessToken: s.accessToken, clientToken: s.clientToken);
}
