import 'package:flutter/material.dart';

import '../app_scope.dart';

import 'package:flutter/services.dart';

import '../core/ai/ai_client.dart';
import '../core/ai/ai_context.dart';
import '../core/secure.dart';
import '../platform.dart';
import '../shell.dart' show ShellNav;
import 'ai_mcp_settings.dart';

/// AI 排障的接口设置：用户自己填写接口地址、模型与 API Key
class AiSettingsForm extends StatefulWidget {
  const AiSettingsForm({super.key, this.onSaved, this.showButtons = true});

  final VoidCallback? onSaved;

  /// 在对话框中时，保存与测试按钮放在对话框底部
  final bool showButtons;

  @override
  State<AiSettingsForm> createState() => AiSettingsFormState();
}

class AiSettingsFormState extends State<AiSettingsForm> {
  bool _loaded = false;
  late AiProvider _provider;
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  final _ctx = TextEditingController();
  bool _showKey = false;

  /// 手机上密码框会让输入法切换成安全键盘（横屏时挤占界面、无法粘贴），
  /// 所以输入时显示明文，离开输入框后再隐藏
  final _keyFocus = FocusNode();
  bool _testing = false;
  String? _result;
  bool _ok = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final s = AiSettings.load(AppScope.read(context).config);
    _provider = s.provider;
    _url.text = s.baseUrl;
    _model.text = s.model;
    _key.text = s.apiKey;
    final ctx = AppScope.read(context).config.aiContextWindow;
    _ctx.text = ctx > 0 ? '$ctx' : '';
    _keyFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    _ctx.dispose();
    _keyFocus.dispose();
    super.dispose();
  }

  AiSettings get _current =>
      AiSettings(provider: _provider, baseUrl: _url.text.trim(), model: _model.text.trim(), apiKey: _key.text.trim());

  Future<void> save() async {
    final cfg = AppScope.read(context).config;
    await _current.save(cfg);
    await cfg.update({'aiContextWindow': int.tryParse(_ctx.text.trim()) ?? 0});
    if (!mounted) return;
    toast(context, '已保存');
    widget.onSaved?.call();
  }

  Future<void> test() async {
    final s = _current;
    if (!s.ready) {
      setState(() {
        _ok = false;
        _result = '请填写接口地址、模型${s.isLocal ? '' : '和 API Key'}';
      });
      return;
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      final reply = await aiChat(s, '你是一个连接测试助手。', const [AiMessage('user', '只回复两个字：成功')]).join();
      setState(() {
        _ok = true;
        _result = '连接成功，模型回复：${reply.trim().characters.take(40)}';
      });
    } catch (e) {
      setState(() {
        _ok = false;
        _result = errorText(e);
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 从剪贴板粘贴（不需要点开输入框，手机上不会弹出键盘）
  Widget _pasteButton(TextEditingController c) => IconButton(
    tooltip: '粘贴',
    icon: const Icon(Icons.content_paste),
    onPressed: () async {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
      if (!mounted) return;
      if (text.isEmpty) return toast(context, '剪贴板是空的');
      setState(() => c.text = text);
      toast(context, '已粘贴');
    },
  );

  bool _loadingModels = false;

  /// 从接口获取模型列表并选择
  Future<void> _pickModel() async {
    setState(() => _loadingModels = true);
    List<String> models;
    try {
      models = await aiListModels(_current);
    } catch (e) {
      if (mounted) {
        setState(() {
          _ok = false;
          _result = errorText(e);
        });
        toast(context, errorText(e));
      }
      return;
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
    if (!mounted) return;
    if (models.isEmpty) return toast(context, '接口没有返回可用的模型');
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _ModelPicker(models: models, current: _model.text.trim()),
    );
    if (picked != null) setState(() => _model.text = picked);
  }

  bool get testing => _testing;

  /// 测试连接的结果；对话框中显示在按钮旁
  Widget get resultText => _result == null
      ? const SizedBox.shrink()
      : Text(
          _result!,
          style: TextStyle(color: _ok ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error),
        );

  Widget get testLabel => _testing
      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
      : const Text('测试连接');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cfg = AppScope.of(context).config;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('常用服务', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in aiPresets)
              ActionChip(
                label: Text(preset.label),
                onPressed: () => setState(() {
                  _provider = preset.provider;
                  _url.text = preset.url;
                  // 没有推荐模型的服务清空模型，避免沿用其他服务的模型名
                  _model.text = preset.model;
                }),
              ),
          ],
        ),
        const SizedBox(height: 16),
        SegmentedButton<AiProvider>(
          segments: const [
            ButtonSegment(value: AiProvider.openai, label: Text('OpenAI 兼容接口')),
            ButtonSegment(value: AiProvider.anthropic, label: Text('Anthropic 接口')),
          ],
          selected: {_provider},
          onSelectionChanged: (s) => setState(() => _provider = s.first),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _url,
          decoration: InputDecoration(
            labelText: '接口地址',
            hintText: _provider == AiProvider.anthropic ? 'https://api.anthropic.com' : 'https://api.example.com/v1',
            border: const OutlineInputBorder(),
            suffixIcon: _pasteButton(_url),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _key,
          focusNode: _keyFocus,
          obscureText: !_showKey && (isDesktop || !_keyFocus.hasFocus),
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'API Key',
            helperText: '${SecureData.available ? '加密保存在本机' : '保存在启动器的私有数据目录（未加密）'}，只会发送给上面填写的接口地址；本机运行的服务可以不填',
            border: const OutlineInputBorder(),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _pasteButton(_key),
                IconButton(
                  tooltip: _showKey ? '隐藏' : '显示',
                  icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _model,
          decoration: InputDecoration(
            labelText: '模型',
            hintText: '点右侧按钮从接口获取可用的模型',
            border: const OutlineInputBorder(),
            suffixIcon: _loadingModels
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(tooltip: '获取模型列表', icon: const Icon(Icons.list_alt), onPressed: _pickModel),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _ctx,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: '上下文长度（tokens）',
                  hintText: '留空自动：${knownContextWindow(_model.text.trim()) ?? defaultContextWindow}',
                  helperText: '见服务商文档；未知的模型默认按 $defaultContextWindow 计算',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: const [32000, 64000, 128000, 256000, 0].contains(cfg.aiCompactAt)
                    ? cfg.aiCompactAt
                    : 64000,
                decoration: const InputDecoration(
                  labelText: '自动压缩上下文',
                  helperText: '超过后把较早的对话压缩成摘要，节省费用',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 32000, child: Text('超过 32k tokens 时')),
                  DropdownMenuItem(value: 64000, child: Text('超过 64k tokens 时')),
                  DropdownMenuItem(value: 128000, child: Text('超过 128k tokens 时')),
                  DropdownMenuItem(value: 256000, child: Text('超过 256k tokens 时')),
                  DropdownMenuItem(value: 0, child: Text('不自动压缩')),
                ],
                onChanged: (v) => cfg.update({'aiCompactAt': v ?? 64000}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('发送前确认内容'),
          subtitle: const Text('每次分析前显示将要发送的日志与环境信息'),
          value: cfg.aiConfirm,
          onChanged: (v) => cfg.update({'aiConfirm': v}),
        ),
        if (widget.showButtons) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(onPressed: save, child: const Text('保存')),
              const SizedBox(width: 12),
              OutlinedButton(onPressed: _testing ? null : test, child: testLabel),
            ],
          ),
        ],
        if (_result != null && widget.showButtons) ...[const SizedBox(height: 12), resultText],
      ],
    );
  }
}

/// AI 设置里「工具与服务」一页：是否允许 AI 操作、查看类操作是否确认、各个 MCP 服务
class AiToolsSettings extends StatelessWidget {
  const AiToolsSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final cfg = AppScope.of(context).config;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('允许 AI 使用工具'),
          subtitle: const Text('查看版本、模组与日志，安装或禁用模组，联网搜索，以及下面的 MCP 服务；会修改内容的操作都需要你确认'),
          value: cfg.aiTools,
          onChanged: (v) => cfg.update({'aiTools': v}),
        ),
        if (cfg.aiTools)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('查看类操作也需要确认'),
            subtitle: const Text('关闭时，AI 查看版本、模组、文件与日志不需要确认'),
            value: cfg.aiConfirmRead,
            onChanged: (v) => cfg.update({'aiConfirmRead': v}),
          ),
        if (cfg.aiTools) const AiMcpSettings(),
      ],
    );
  }
}

/// 打开 AI 设置：在主界面里切到「设置」页的对应 AI 小节（[section] 为 ai、aiTools 或 aiWorkspace）；
/// 不在主界面里时（例如还没有外壳的场景）退回单独的页面
Future<void> showAiSettingsDialog(BuildContext context, {String section = 'ai'}) async {
  final nav = ShellNav.maybeOf(context);
  if (nav != null) {
    nav.openSettings(section);
    return;
  }
  // 手机上键盘会占掉大半屏幕，用全屏页面代替对话框
  if (!isDesktop) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('AI 排障设置')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            children: [AiSettingsForm(onSaved: () => Navigator.pop(context))],
          ),
        ),
      ),
    );
    return;
  }
  final form = GlobalKey<AiSettingsFormState>();
  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: const Text('AI 排障设置'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: AiSettingsForm(key: form, showButtons: false, onSaved: () => Navigator.pop(context)),
          ),
        ),
        actionsOverflowButtonSpacing: 8,
        actions: [
          if (form.currentState != null) SizedBox(width: 240, child: form.currentState!.resultText),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          OutlinedButton(
            onPressed: form.currentState?.testing ?? false
                ? null
                : () async {
                    final t = form.currentState?.test();
                    setLocal(() {});
                    await t;
                    if (context.mounted) setLocal(() {});
                  },
            child: form.currentState?.testLabel ?? const Text('测试连接'),
          ),
          FilledButton(onPressed: () => form.currentState?.save(), child: const Text('保存')),
        ],
      ),
    ),
  );
}

/// 模型选择：可以输入筛选
class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.models, required this.current});

  final List<String> models;
  final String current;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final list = widget.models.where((m) => m.toLowerCase().contains(_filter.toLowerCase())).toList();
    return AlertDialog(
      title: Text('选择模型（${widget.models.length} 个）'),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '筛选',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _filter = v.trim()),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: list.isEmpty
                  ? const Center(child: Text('没有匹配的模型'))
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) => ListTile(
                        dense: true,
                        title: Text(list[i]),
                        selected: list[i] == widget.current,
                        trailing: list[i] == widget.current ? const Icon(Icons.check) : null,
                        onTap: () => Navigator.pop(context, list[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消'))],
    );
  }
}
