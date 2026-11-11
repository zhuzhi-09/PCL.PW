import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/auth/auth.dart';
import '../core/auth/yggdrasil.dart';
import '../core/auth/yggdrasil_connect.dart';
import 'device_login_dialog.dart';

/// 外置登录：先填写或选择验证服务器地址，再登录。内置支持 Yggdrasil Connect 的站点默认 OAuth 授权登录，
/// 可以和账户密码登录来回切换；其他地址只能账户密码登录（Yggdrasil API）。[run] 默认为 AppState.login
Future<void> showYggdrasilLogin(BuildContext context, {LoginRunner? run}) async {
  final runner = run ?? AppScope.read(context).login;
  final address = await showDialog<String>(context: context, builder: (_) => const _AddressDialog());
  if (address == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _LoginDialog(address, YggdrasilConnect.builtInSite(address), runner),
  );
}

/// 第一步：验证服务器地址。可以直接输入，也可以从内置站点中选择；返回地址
class _AddressDialog extends StatefulWidget {
  const _AddressDialog();

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final _address = TextEditingController();

  @override
  void initState() {
    super.initState();
    _address.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final address = _address.text.trim();
    return AlertDialog(
      icon: const Icon(Icons.dns_outlined),
      title: const Text('外置登录'),
      content: SizedBox(
        width: 400,
        child: DropdownMenu<String>(
          controller: _address,
          requestFocusOnTap: true,
          enableFilter: true,
          expandedInsets: EdgeInsets.zero,
          label: const Text('验证服务器地址'),
          hintText: '输入地址，或从列表中选择',
          dropdownMenuEntries: [
            for (final site in YggdrasilConnect.builtInClientIds.keys)
              DropdownMenuEntry(value: site, label: site, trailingIcon: const Text('OAuth')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: address.isEmpty ? null : () => Navigator.pop(context, address),
          child: const Text('下一步'),
        ),
      ],
    );
  }
}

/// 第二步：登录。[site] 不为空（内置站点）时可以在 OAuth 授权与账户密码之间切换，默认显示 OAuth，
/// 点「开始 OAuth 登录」后才开始；两种方式的状态都保留，OAuth 在切到账户密码时继续等待授权
class _LoginDialog extends StatefulWidget {
  const _LoginDialog(this.server, this.site, this.run);

  final String server;
  final String? site;
  final LoginRunner run;

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  late bool _oauth = widget.site != null;
  final _username = TextEditingController();
  final _password = TextEditingController();
  YggdrasilLogin? _login;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _login?.cancel();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _username.text.trim().isEmpty || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final login = _login = YggdrasilLogin(
      server: widget.server,
      username: _username.text.trim(),
      password: _password.text,
      chooseProfile: _chooseProfile,
    );
    try {
      final acc = await widget.run(login);
      if (mounted) loggedIn(context, acc);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          if (e is! LoginCancelled) _error = errorText(e);
        });
      }
    }
  }

  Future<GameProfile?> _chooseProfile(List<GameProfile> profiles) => showDialog<GameProfile>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('选择角色'),
      children: [
        for (final p in profiles) SimpleDialogOption(onPressed: () => Navigator.pop(context, p), child: Text(p.name)),
      ],
    ),
  );

  Widget _passwordForm(ThemeData theme) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '验证服务器：${widget.server}',
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      if (widget.server.toLowerCase().startsWith('http://')) ...[
        const SizedBox(height: 4),
        Text('这个地址没有加密，密码会以明文传输', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
      ],
      const SizedBox(height: 16),
      TextField(
        controller: _username,
        enabled: !_busy,
        autofocus: widget.site == null,
        decoration: const InputDecoration(labelText: '账户', hintText: '邮箱或用户名', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _password,
        enabled: !_busy,
        obscureText: true,
        decoration: const InputDecoration(labelText: '密码', border: OutlineInputBorder()),
        onSubmitted: (_) => _submit(),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final site = widget.site;
    return AlertDialog(
      icon: const Icon(Icons.dns_outlined),
      title: Text(site ?? '账户密码登录'),
      content: SizedBox(
        width: 400,
        child: site == null
            ? _passwordForm(theme)
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, icon: Icon(Icons.open_in_browser), label: Text('OAuth 授权')),
                      ButtonSegment(value: false, icon: Icon(Icons.password), label: Text('账户密码')),
                    ],
                    selected: {_oauth},
                    onSelectionChanged: (s) => setState(() => _oauth = s.first),
                  ),
                  const SizedBox(height: 16),
                  Visibility(
                    visible: _oauth,
                    maintainState: true,
                    child: DeviceLoginPanel(
                      create: (onCode) => ConnectLogin(site, onCode),
                      run: widget.run,
                      onDone: (acc) => loggedIn(context, acc),
                      intro: '点击开始后会在浏览器中打开 $site 的授权页面，确认授权并选择角色即可，启动器不会接触你的密码。',
                      startLabel: '开始 OAuth 登录',
                    ),
                  ),
                  Visibility(visible: !_oauth, maintainState: true, child: _passwordForm(theme)),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        if (!_oauth)
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('登录'),
          ),
      ],
    );
  }
}
