import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_scope.dart';
import '../core/accounts.dart';
import '../core/auth/auth.dart';

/// 设备代码登录对话框（微软）。[create] 用展示代码的回调创建登录命令
Future<void> showDeviceLogin(
  BuildContext context, {
  required String title,
  required LoginCommand Function(void Function(DeviceCode) onCode) create,
}) {
  final run = AppScope.read(context).login;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.account_circle_outlined),
      title: Text(title),
      content: SizedBox(
        width: 400,
        child: DeviceLoginPanel(create: create, run: run, onDone: (acc) => loggedIn(context, acc), autoStart: true),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消'))],
    ),
  );
}

void loggedIn(BuildContext context, Account acc) {
  Navigator.pop(context);
  toast(context, '已登录 ${acc.name}');
}

/// 设备代码登录的内容：用户点「开始」（或 [autoStart] 时创建后立即）开始，显示代码并打开授权页面，
/// 用户在浏览器中完成后调用 [onDone]；失败或超时可以重试。可以放进任意登录对话框
class DeviceLoginPanel extends StatefulWidget {
  const DeviceLoginPanel({
    super.key,
    required this.create,
    required this.run,
    required this.onDone,
    this.autoStart = false,
    this.intro,
    this.startLabel = '开始登录',
  });

  final LoginCommand Function(void Function(DeviceCode) onCode) create;
  final LoginRunner run;
  final void Function(Account acc) onDone;
  final bool autoStart;

  /// 开始前显示的说明
  final String? intro;
  final String startLabel;

  @override
  State<DeviceLoginPanel> createState() => _DeviceLoginPanelState();
}

class _DeviceLoginPanelState extends State<DeviceLoginPanel> {
  LoginCommand? _login;
  DeviceCode? _code;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) _start();
  }

  void _start() {
    final login = _login = widget.create(_onCode);
    _code = null;
    _error = null;
    widget
        .run(login)
        .then((acc) {
          if (mounted && identical(login, _login)) widget.onDone(acc);
        })
        .catchError((Object e) {
          if (e is! LoginCancelled && mounted && identical(login, _login)) setState(() => _error = errorText(e));
        });
  }

  void _onCode(DeviceCode c) {
    if (mounted) setState(() => _code = c);
    Clipboard.setData(ClipboardData(text: c.userCode));
    launchUrl(Uri.parse(c.completeUri ?? c.verificationUri));
  }

  @override
  void dispose() {
    _login?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = _code;
    if (_login == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.intro != null) ...[Text(widget.intro!), const SizedBox(height: 16)],
          FilledButton.icon(
            onPressed: () => setState(_start),
            icon: const Icon(Icons.open_in_browser),
            label: Text(widget.startLabel),
          ),
        ],
      );
    }
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(height: 8),
          TextButton.icon(onPressed: () => setState(_start), icon: const Icon(Icons.refresh), label: const Text('重试')),
        ],
      );
    }
    if (code == null) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: LinearProgressIndicator());
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(code.completeUri != null ? '已在浏览器中打开授权页面，请确认页面上的代码与下面一致后完成授权：' : '已在浏览器中打开登录页面，请输入下面的代码（已复制到剪贴板）：'),
        const SizedBox(height: 16),
        SelectableText(
          code.userCode,
          style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: 4, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => launchUrl(Uri.parse(code.completeUri ?? code.verificationUri)),
          child: Text(code.verificationUri),
        ),
        const SizedBox(height: 8),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('等待登录完成'),
          ],
        ),
      ],
    );
  }
}
