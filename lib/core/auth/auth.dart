import '../accounts.dart';

/// 一次登录（命令模式）：执行后得到一个新账户
abstract interface class LoginCommand {
  Future<Account> execute();

  /// 放弃登录（关闭登录对话框时调用）
  void cancel();
}

/// 执行登录命令并保存结果（AppState.login）；界面通过它执行命令，测试中可以替换
typedef LoginRunner = Future<Account> Function(LoginCommand command);

/// 启动用的账户（令牌可能已刷新）与需要加到 JVM 参数里的内容
typedef AuthSession = ({Account account, List<String> jvmArgs});

/// 某类账户启动前的处理
abstract interface class AccountAuth {
  Future<AuthSession> prepare(Account acc, AuthPrompts prompts);
}

/// 验证过程中需要用户参与的操作
abstract interface class AuthPrompts {
  /// 令牌无法续期时请用户重新输入密码；取消时返回 null
  Future<String?> askPassword(Account acc);
}

class OfflineAuth implements AccountAuth {
  const OfflineAuth();

  @override
  Future<AuthSession> prepare(Account acc, AuthPrompts prompts) async => (account: acc, jvmArgs: const <String>[]);
}

/// 设备代码流中展示给用户的代码与授权页面
class DeviceCode {
  DeviceCode({required this.userCode, required this.verificationUri, this.completeUri});

  final String userCode;
  final String verificationUri;

  /// 已带上用户代码的授权页面（服务器提供时），打开后不需要手动输入代码
  final String? completeUri;
}

/// Yggdrasil 角色（不含属性）
class GameProfile {
  const GameProfile(this.id, this.name);

  /// 无符号 UUID
  final String id;
  final String name;

  static GameProfile? tryParse(Object? j) =>
      j is Map && j['id'] != null && j['name'] != null ? GameProfile('${j['id']}', '${j['name']}') : null;

  Map<String, String> toJson() => {'id': id, 'name': name};
}

/// 登录时选择角色；返回 null 表示取消
typedef ProfileChooser = Future<GameProfile?> Function(List<GameProfile> profiles);

class LoginCancelled implements Exception {
  const LoginCancelled();

  @override
  String toString() => '已取消登录';
}
