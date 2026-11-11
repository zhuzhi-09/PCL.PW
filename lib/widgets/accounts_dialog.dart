import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/accounts.dart';
import '../core/microsoft.dart';
import 'device_login_dialog.dart';
import 'yggdrasil_login_dialog.dart';

/// 账户管理：切换、添加离线 / 微软 / 外置登录账户、移除
Future<void> showAccountsDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _AccountsDialog());

class _AccountsDialog extends StatefulWidget {
  const _AccountsDialog();

  @override
  State<_AccountsDialog> createState() => _AccountsDialogState();
}

class _AccountsDialogState extends State<_AccountsDialog> {
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    final error = AccountStore.validateOfflineName(name);
    if (error != null) return setState(() => _error = error);
    await AppScope.read(context).addOfflineAccount(name);
    _name.clear();
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final selected = state.selectedAccount?.id;
    return AlertDialog(
      title: const Text('账户'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.accounts.accounts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('还没有账户', style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            for (final a in state.accounts.accounts)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                selected: a.id == selected,
                selectedTileColor: scheme.secondaryContainer,
                leading: CircleAvatar(child: Text(a.name.characters.first.toUpperCase())),
                title: Text(a.name),
                subtitle: Text(a.typeLabel),
                onTap: () => state.selectAccount(a.id),
                trailing: IconButton(
                  tooltip: '移除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => state.removeAccount(a.id),
                ),
              ),
            const SizedBox(height: 16),
            Text('添加离线账户', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    decoration: InputDecoration(
                      labelText: '用户名',
                      errorText: _error,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: FilledButton.tonal(onPressed: _add, child: const Text('添加')),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text('正版账户', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: () => showDeviceLogin(
                  context,
                  title: '微软登录',
                  create: (onCode) => MicrosoftLogin(state.config.effectiveMsClientId, onCode),
                ),
                icon: const Icon(Icons.login),
                label: const Text('微软登录'),
              ),
            ),
            if (state.config.effectiveMsClientId.trim().isEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '微软登录需要先在「设置 - 其他」中填写 Azure 应用 Client ID。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 20),
            Text('第三方账户', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: () => showYggdrasilLogin(context),
                icon: const Icon(Icons.dns_outlined),
                label: const Text('外置登录'),
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成'))],
    );
  }
}
