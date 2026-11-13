import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../accounts.dart' show newId;
import 'ai_client.dart';
import 'ai_context.dart';
import 'ai_prompt.dart';
import 'ai_tools.dart';
import 'mcp_hub.dart';
import '../paths.dart';

/// 工具调用的结果状态
enum ToolStatus { done, denied, error, cancelled }

class ChatMessage {
  ChatMessage(
    this.role,
    this.content, {
    DateTime? time,
    this.toolCalls = const [],
    this.blocks,
    this.reasoning,
    this.toolCallId,
    this.status,
    this.title,
    this.details = const [],
    this.inputTokens,
    this.outputTokens,
    this.ms,
  }) : time = time ?? DateTime.now();

  /// user、assistant 或 tool（工具结果，显示在对应的工具卡片里）
  final String role;

  /// 文字；工具结果为返回给模型的内容
  final String content;
  final DateTime time;

  /// assistant：请求调用的工具
  final List<AiToolCall> toolCalls;

  /// assistant：需要原样传回接口的内容（见 [AiMessage]）
  final List<Map<String, dynamic>>? blocks;
  final String? reasoning;

  /// tool：对应的调用、状态，以及确认卡片上的标题与详情
  final String? toolCallId;
  final ToolStatus? status;
  final String? title;
  final List<String> details;

  /// assistant：这次请求的用量与生成用时（毫秒）
  final int? inputTokens;
  final int? outputTokens;
  final int? ms;

  bool get isUser => role == 'user';
  bool get isTool => role == 'tool';

  /// keepBlocks 为 false 时不传回原始内容块（压缩过的对话中已完成的轮次）
  AiMessage toAi({bool keepBlocks = true}) => AiMessage(
    role,
    content,
    toolCalls: toolCalls,
    blocks: keepBlocks ? blocks : null,
    reasoning: reasoning,
    toolCallId: toolCallId,
    isError: status == ToolStatus.error,
  );

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    'time': time.toIso8601String(),
    if (toolCalls.isNotEmpty) 'toolCalls': [for (final c in toolCalls) c.toJson()],
    'blocks': ?blocks,
    'reasoning': ?reasoning,
    'toolCallId': ?toolCallId,
    'status': ?status?.name,
    'title': ?title,
    if (details.isNotEmpty) 'details': details,
    'inputTokens': ?inputTokens,
    'outputTokens': ?outputTokens,
    'ms': ?ms,
  };

  static ChatMessage fromJson(Map<String, dynamic> j) => ChatMessage(
    '${j['role']}',
    '${j['content']}',
    time: DateTime.tryParse('${j['time']}'),
    toolCalls: [
      for (final c in (j['toolCalls'] as List? ?? const []).whereType<Map<String, dynamic>>()) AiToolCall.fromJson(c),
    ],
    blocks: (j['blocks'] as List?)?.whereType<Map<String, dynamic>>().toList(),
    reasoning: j['reasoning'] as String?,
    toolCallId: j['toolCallId'] as String?,
    status: ToolStatus.values.asNameMap()[j['status']],
    title: j['title'] as String?,
    details: (j['details'] as List? ?? const []).map((e) => '$e').toList(),
    inputTokens: (j['inputTokens'] as num?)?.toInt(),
    outputTokens: (j['outputTokens'] as num?)?.toInt(),
    ms: (j['ms'] as num?)?.toInt(),
  );
}

/// 一次对话，保存在应用数据目录的 `ai_sessions/<id>.json`
class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.created,
    required this.updated,
    required this.messages,
    this.summary,
    this.summaryUntil = 0,
    this.summaryAt = 0,
  });

  final String id;
  String title;
  final DateTime created;
  DateTime updated;
  final List<ChatMessage> messages;

  /// 上下文压缩：summaryUntil 之前的消息发给模型时用 summary 代替（界面上仍然显示）
  String? summary;
  int summaryUntil;

  /// 压缩时的消息数：在此之前的用量是压缩前测得的，不再代表当前上下文
  int summaryAt;

  /// 某个工具调用的结果
  ChatMessage? resultOf(String callId) => messages.where((m) => m.isTool && m.toolCallId == callId).firstOrNull;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'created': created.toIso8601String(),
    'updated': updated.toIso8601String(),
    'messages': [for (final m in messages) m.toJson()],
    'summary': ?summary,
    if (summary != null) 'summaryUntil': summaryUntil,
    if (summary != null) 'summaryAt': summaryAt,
  };

  static ChatSession fromJson(Map<String, dynamic> j) => ChatSession(
    id: '${j['id']}',
    title: '${j['title']}',
    created: DateTime.tryParse('${j['created']}') ?? DateTime.now(),
    updated: DateTime.tryParse('${j['updated']}') ?? DateTime.now(),
    messages: [
      for (final m in (j['messages'] as List? ?? const []).whereType<Map<String, dynamic>>()) ChatMessage.fromJson(m),
    ],
    summary: j['summary'] as String?,
    summaryUntil: (j['summaryUntil'] as num?)?.toInt() ?? 0,
    summaryAt: (j['summaryAt'] as num?)?.toInt() ?? 0,
  );
}

/// 进行中的工具调用：准备中、等待用户确认或执行中
class PendingTool {
  PendingTool(this.sessionId, this.call, this.def);

  final String sessionId;
  final AiToolCall call;
  HubTool? def;
  ToolPlan? plan;
  bool running = false;
  Completer<bool>? _decision;

  bool get waiting => _decision != null && !_decision!.isCompleted;
}

/// AI 对话的会话列表、正在进行的回答与工具调用
class ChatStore extends ChangeNotifier {
  ChatStore._(this.sessions);

  /// 按最后更新时间排序，新的在前
  final List<ChatSession> sessions;

  /// 工具的统一出入口（内置服务与外部 MCP 服务），由 AppState 设置
  McpHub? hub;

  /// 是否向模型提供操作，以及只读操作是否也需要确认
  bool Function() toolsEnabled = () => true;
  bool Function() confirmRead = () => false;

  /// 模型的上下文长度，以及自动压缩的阈值（0 表示不自动压缩）
  int Function(AiSettings) contextWindow = (_) => defaultContextWindow;
  int Function() compactAt = () => 64000;

  /// 当前打开的会话；null 表示新对话（发送第一条消息时创建）
  String? currentId;

  final _streaming = <String, String>{};
  final _errors = <String, String>{};
  final _busy = <String>{};
  final _compacting = <String>{};

  /// 每次停止时加一，用来丢弃已停止的请求的后续结果
  final _gen = <String, int>{};
  final _pending = <String, PendingTool>{};

  /// 本次对话中已允许的操作（只限 write 类）
  final _allowed = <String, Set<String>>{};

  static Directory get _dir => Directory(p.join(Paths.appData, 'ai_sessions'));

  static ChatStore load() {
    final list = <ChatSession>[];
    try {
      if (_dir.existsSync()) {
        for (final f in _dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
          try {
            list.add(ChatSession.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>));
          } catch (_) {
            // 损坏的会话文件跳过
          }
        }
      }
    } catch (_) {
      // 目录无法读取
    }
    return ChatStore._(list..sort((a, b) => b.updated.compareTo(a.updated)));
  }

  ChatSession? get current => sessions.where((s) => s.id == currentId).firstOrNull;
  ChatSession? byId(String id) => sessions.where((s) => s.id == id).firstOrNull;

  bool isBusy(String id) => _busy.contains(id);
  bool isCompacting(String id) => _compacting.contains(id);

  /// 当前上下文的用量：最近一次请求的实际用量加上之后新增的内容；没有用量数据时估算
  ({int used, int window, bool estimated}) contextOf(ChatSession s, AiSettings ai) {
    final window = contextWindow(ai);
    final ms = s.messages;
    final last = ms.lastIndexWhere((m) => m.inputTokens != null);
    if (last >= 0 && (s.summary == null || last >= s.summaryAt)) {
      final after = ms.skip(last + 1).fold<int>(0, (a, m) => a + estimateTokens(m.content));
      return (used: ms[last].inputTokens! + (ms[last].outputTokens ?? 0) + after, window: window, estimated: after > 0);
    }
    final text = [s.summary ?? '', for (final m in ms.skip(s.summary == null ? 0 : s.summaryUntil)) m.content].join();
    return (used: promptOverheadTokens + estimateTokens(text), window: window, estimated: true);
  }

  /// 压缩的分界：保留最近 [keepRecentTurns] 轮，分界总在用户消息处，不会拆开工具调用与结果
  int? _cutIndex(ChatSession s) {
    final users = [
      for (var i = 0; i < s.messages.length; i++)
        if (s.messages[i].isUser && i > s.summaryUntil) i,
    ];
    if (users.length < keepRecentTurns) return null;
    final cut = users[users.length - keepRecentTurns];
    return cut > s.summaryUntil ? cut : null;
  }

  bool canCompact(ChatSession s) => _cutIndex(s) != null;

  /// 把较早的对话压缩成摘要；成功时返回 true
  Future<bool> compact(ChatSession s, AiSettings ai) async {
    final cut = _cutIndex(s);
    if (cut == null || _compacting.contains(s.id)) return false;
    _compacting.add(s.id);
    _errors.remove(s.id);
    notifyListeners();
    try {
      final text = transcriptOf(
        s.messages
            .sublist(s.summary == null ? 0 : s.summaryUntil, cut)
            .map(
              (m) => (
                role: m.role,
                content: m.content,
                calls: [for (final c in m.toolCalls) (name: c.name, args: c.args)],
              ),
            ),
      );
      final prompt = '${s.summary == null ? '' : '【已有的摘要】\n${s.summary}\n\n'}【需要压缩的对话】\n$text';
      final out = StringBuffer();
      await for (final e in aiStream(ai, compactSystemPrompt, [AiMessage('user', prompt)])) {
        if (e is AiText) out.write(e.text);
      }
      final summary = out.toString().trim();
      if (summary.isEmpty) throw AiException('模型没有返回摘要');
      s
        ..summary = summary
        ..summaryUntil = cut
        ..summaryAt = s.messages.length;
      await _save(s);
      return true;
    } catch (e) {
      _errors[s.id] = '压缩上下文失败：$e';
      return false;
    } finally {
      _compacting.remove(s.id);
      notifyListeners();
    }
  }

  /// 正在生成的回答（尚未完成）
  String? streamingOf(String id) => _streaming[id];
  String? errorOf(String id) => _errors[id];
  PendingTool? pendingOf(String callId) => _pending[callId];

  /// 正在执行操作时不能停止，避免操作实际执行了却被记为取消
  bool isExecuting(String id) => _pending.values.any((t) => t.sessionId == id && t.running);

  void open(String? id) {
    currentId = id;
    notifyListeners();
  }

  Future<void> _save(ChatSession s) async {
    try {
      await _dir.create(recursive: true);
      await File(p.join(_dir.path, '${s.id}.json')).writeAsString(jsonEncode(s.toJson()));
    } catch (_) {
      // 保存失败不影响对话
    }
  }

  /// 第一条消息的第一行作为标题
  static String titleFrom(String text) {
    final line = text.trim().split('\n').first.trim();
    return line.length > 30 ? '${line.substring(0, 30)}…' : (line.isEmpty ? '新对话' : line);
  }

  /// 发送消息；session 为 null 时新建会话。返回消息所在的会话
  ///
  /// [systemExtra] 追加在系统提示后面（只用于这次请求，不保存）；[interactive] 为 false 时
  /// 没有人能在启动器里确认操作（例如问题来自游戏内），需要确认的操作直接拒绝。
  /// [focus] 为 false 时不切换启动器里当前打开的会话。
  ChatSession send(
    ChatSession? session,
    String text,
    AiSettings ai, {
    String? title,
    String? systemExtra,
    bool interactive = true,
    bool focus = true,
  }) {
    final now = DateTime.now();
    final s =
        session ?? ChatSession(id: newId(), title: title ?? titleFrom(text), created: now, updated: now, messages: []);
    if (session == null) sessions.insert(0, s);
    s.messages.add(ChatMessage('user', text));
    if (focus) currentId = s.id;
    unawaited(_sendFlow(s, ai, systemExtra: systemExtra, interactive: interactive));
    return s;
  }

  /// 导入其他地方保存的对话（例如旧版游戏内助手的记录）；id 已存在的跳过。返回导入的数量
  Future<int> importSessions(Iterable<ChatSession> list) async {
    var count = 0;
    for (final s in list) {
      if (s.messages.isEmpty || byId(s.id) != null) continue;
      sessions.add(s);
      await _save(s);
      count++;
    }
    if (count > 0) {
      sessions.sort((a, b) => b.updated.compareTo(a.updated));
      notifyListeners();
    }
    return count;
  }

  /// 上下文超过阈值（不超过上下文长度的 75%）时先压缩，再请求回答
  Future<void> _sendFlow(ChatSession s, AiSettings ai, {String? systemExtra, bool interactive = true}) async {
    final at = compactAt();
    if (at > 0 && canCompact(s)) {
      final c = contextOf(s, ai);
      final limit = at < c.window * 0.75 ? at : (c.window * 0.75).round();
      if (c.used > limit) {
        final gen = _gen[s.id] ?? 0;
        _busy.add(s.id);
        await compact(s, ai);
        // 压缩期间用户停止了对话
        if ((_gen[s.id] ?? 0) != gen) return;
      }
    }
    await _run(s, ai, systemExtra: systemExtra, interactive: interactive);
  }

  /// 重新生成：去掉最后一条文字回答（如果有），再次请求
  void retry(ChatSession s, AiSettings ai) {
    if (isBusy(s.id) || s.messages.isEmpty) return;
    final last = s.messages.last;
    if (last.role == 'assistant' && last.toolCalls.isEmpty) s.messages.removeLast();
    unawaited(_run(s, ai));
  }

  /// 发给接口的历史：没有结果的工具调用（例如确认时关闭了启动器）补上「已取消」
  List<AiMessage> _history(ChatSession s) {
    final out = <AiMessage>[];
    final start = s.summary == null ? 0 : s.summaryUntil.clamp(0, s.messages.length);
    // 压缩后历史的开头变了，已完成的轮次不再传回原始内容块（思考块与原来的上下文绑定）
    final lastUser = s.messages.lastIndexWhere((m) => m.isUser);
    if (s.summary != null) out.add(AiMessage('user', '$summaryLead\n\n${s.summary}'));
    for (var i = start; i < s.messages.length; i++) {
      final m = s.messages[i];
      out.add(m.toAi(keepBlocks: s.summary == null || i > lastUser));
      if (m.toolCalls.isEmpty) continue;
      // 这条回答之后紧跟的工具结果
      final answered = <String>{};
      for (var j = i + 1; j < s.messages.length && s.messages[j].isTool; j++) {
        answered.add(s.messages[j].toolCallId ?? '');
      }
      for (final c in m.toolCalls.where((c) => !answered.contains(c.id))) {
        out.add(AiMessage('tool', '操作已取消，没有执行。', toolCallId: c.id, isError: true));
      }
    }
    return out;
  }

  Future<void> _run(ChatSession s, AiSettings ai, {String? systemExtra, bool interactive = true}) async {
    final gen = _gen[s.id] ?? 0;
    bool stopped() => (_gen[s.id] ?? 0) != gen;
    _errors.remove(s.id);
    _busy.add(s.id);
    _bump(s);
    unawaited(_save(s));
    notifyListeners();
    final toolsOn = hub != null && toolsEnabled();
    try {
      final tools = toolsOn ? await hub!.specs() : const <AiTool>[];
      // 按开启的服务（工作区、联网、外部 MCP 服务）追加说明
      final extra = toolsOn ? await hub!.promptExtra() : null;
      final system = [assistantSystemPrompt, ?extra, ?systemExtra].join('\n\n');
      // 工作区与联网任务需要更多轮工具调用
      for (var round = 0; round < 32; round++) {
        _streaming[s.id] = '';
        notifyListeners();
        AiTurnEnd? end;
        final watch = Stopwatch()..start();
        await for (final e in aiStream(ai, system, _history(s), tools: tools)) {
          if (stopped()) return;
          switch (e) {
            case AiText(:final text):
              _streaming[s.id] = (_streaming[s.id] ?? '') + text;
              notifyListeners();
            case AiTurnEnd():
              end = e;
          }
        }
        if (stopped() || end == null) return;
        final m = end.message;
        _streaming.remove(s.id);
        // 部分 OpenAI 兼容服务的调用 ID 会重复或缺失，在会话内改成唯一的
        // （Anthropic 的 ID 本身唯一，并且要与原始内容块一致，不改）
        final used = {for (final x in s.messages) ...x.toolCalls.map((c) => c.id)};
        final calls = m.blocks != null
            ? m.toolCalls
            : [for (final c in m.toolCalls) used.add(c.id) ? c : AiToolCall('call_${newId()}', c.name, c.args)];
        s.messages.add(
          ChatMessage(
            'assistant',
            m.content,
            toolCalls: calls,
            blocks: m.blocks,
            reasoning: m.reasoning,
            inputTokens: end.inputTokens,
            outputTokens: end.outputTokens,
            ms: watch.elapsedMilliseconds,
          ),
        );
        s.updated = DateTime.now();
        unawaited(_save(s));
        notifyListeners();
        if (calls.isEmpty) return;

        // 依次处理工具调用；只读操作直接执行，其余等用户确认
        for (final call in calls) {
          if (stopped()) return;
          final result = await _handle(s, call, stopped, interactive: interactive);
          if (stopped()) return;
          s.messages.add(result);
          unawaited(_save(s));
          notifyListeners();
        }
      }
      _errors[s.id] = '这一轮的操作次数过多，已暂停。可以发送消息让 AI 继续';
    } catch (e) {
      if (!stopped()) _errors[s.id] = '$e';
    } finally {
      if (!stopped()) {
        _busy.remove(s.id);
        // 失败时保留已生成的文字
        final partial = _streaming.remove(s.id) ?? '';
        if (partial.isNotEmpty) {
          s.messages.add(ChatMessage('assistant', _errors.containsKey(s.id) ? '$partial\n\n（回答中断）' : partial));
        }
        s.updated = DateTime.now();
        unawaited(_save(s));
        notifyListeners();
      }
    }
  }

  Future<ChatMessage> _handle(
    ChatSession s,
    AiToolCall call,
    bool Function() stopped, {
    bool interactive = true,
  }) async {
    final h = hub;
    final pending = _pending[call.id] = PendingTool(s.id, call, h?.find(call.name));
    notifyListeners();
    ChatMessage result(ToolStatus status, String content, {String? title, List<String> details = const []}) =>
        ChatMessage(
          'tool',
          content,
          toolCallId: call.id,
          status: status,
          title: title ?? pending.def?.label ?? call.name,
          details: details,
        );
    var cancelled = false;
    try {
      if (h == null) return result(ToolStatus.error, '没有可用的工具');
      // 所有工具（内置服务与外部 MCP 服务）都经 McpHub 调用；服务的权限（只读时直接拒绝）也在那里处理，
      // 这里只负责向用户确认
      final out = await h.call(
        call.name,
        call.args,
        onPlan: (tool, plan) {
          pending
            ..def = tool
            ..plan = plan;
          notifyListeners();
        },
        onRun: () {
          pending.running = true;
          notifyListeners();
        },
        approve: (tool, plan) async {
          final needsApproval = switch (tool.kind) {
            ToolKind.read => confirmRead(),
            ToolKind.write => !(_allowed[s.id]?.contains(call.name) ?? false),
            ToolKind.danger => true,
          };
          if (!needsApproval) return true;
          if (!interactive) return null;
          pending._decision = Completer<bool>();
          notifyListeners();
          final ok = await pending._decision!.future;
          if (stopped()) {
            cancelled = true;
            return false;
          }
          return ok;
        },
      );
      if (cancelled) return result(ToolStatus.cancelled, '操作已取消，没有执行。', title: out.title, details: out.details);
      return result(
        ToolStatus.values.asNameMap()[out.status] ?? ToolStatus.error,
        out.content,
        title: out.title,
        details: out.details,
      );
    } finally {
      _pending.remove(call.id);
    }
  }

  /// 用户对确认卡片的选择；always 表示本次对话中允许同类操作
  void decide(ChatSession s, String callId, bool allow, {bool always = false}) {
    final pending = _pending[callId];
    if (pending == null || !pending.waiting) return;
    if (allow && always) (_allowed[s.id] ??= {}).add(pending.call.name);
    pending._decision!.complete(allow);
    notifyListeners();
  }

  void stop(ChatSession s) {
    if (!isBusy(s.id) || isExecuting(s.id)) return;
    _gen[s.id] = (_gen[s.id] ?? 0) + 1;
    _busy.remove(s.id);
    final partial = _streaming.remove(s.id) ?? '';
    if (partial.isNotEmpty) s.messages.add(ChatMessage('assistant', '$partial\n\n（已停止）'));
    // 等待确认的操作视为取消（发送下一条消息时会补上「已取消」的结果）
    for (final m in _pending.values.toList()) {
      if (m.waiting) m._decision!.complete(false);
    }
    s.updated = DateTime.now();
    unawaited(_save(s));
    notifyListeners();
  }

  /// 最近更新的会话排到最前
  void _bump(ChatSession s) {
    sessions
      ..remove(s)
      ..insert(0, s);
  }

  Future<void> rename(ChatSession s, String title) async {
    s.title = title.trim().isEmpty ? s.title : title.trim();
    notifyListeners();
    await _save(s);
  }

  Future<void> delete(ChatSession s) async {
    stop(s);
    sessions.remove(s);
    _errors.remove(s.id);
    _allowed.remove(s.id);
    if (currentId == s.id) currentId = null;
    notifyListeners();
    try {
      await File(p.join(_dir.path, '${s.id}.json')).delete();
    } catch (_) {
      // 文件已不存在
    }
  }
}
