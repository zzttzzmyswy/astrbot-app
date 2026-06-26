import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart' as md;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/chat_provider.dart';
import '../services/audio_playback_service.dart';
import '../services/audio_service.dart';
import '../providers/platform_providers.dart';
import '../models/botapi_event.dart';
import '../models/message.dart';
import '../widgets/attachment_panel.dart';
import '../widgets/account_drawer.dart';
import '../util/lru_cache.dart';
import 'settings_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});
  @override ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scrollCtrl = ScrollController();
  final _inputCtrl = TextEditingController();
  final _focusNode = FocusNode();
  ChatState _state = const ChatState();

  // 内置斜杠命令提示种子(AstrBot 公认指令;实际可用性以服务端为准)。
  static const List<SlashCommand> _slashCommands = [
    SlashCommand('/provider', '显示、切换后端大模型供应商'),
    SlashCommand('/reset', '清空会话上下文'),
    SlashCommand('/help', '显示详细的帮助指令'),
  ];

  /// 当前应展示的命令候选:输入以 / 开头、且尚在命令段(无空格)时,
  /// 按前缀过滤;一旦输入参数(出现空格)即隐藏,避免干扰参数输入。
  List<SlashCommand> get _slashMatches {
    final t = _inputCtrl.text;
    if (!t.startsWith('/') || t.contains(' ')) return const [];
    return _slashCommands.where((c) => c.cmd.startsWith(t)).toList();
  }

  void _pickSlashCommand(String cmd) {
    _inputCtrl.text = cmd;
    _inputCtrl.selection = TextSelection.collapsed(offset: cmd.length);
    _focusNode.requestFocus();
  }

  double _w = 360;
  int _lastLen = 0;
  ConnState _lastConn = ConnState.disconnected;
  // 消息列表引用:每次 updateUploadProgress/createPendingMedia 等都会产生新列表,
  // 用 identical 检测"列表内容变更"(含进度/状态等就地更新),触发重建;
  // 流式期间只改 streamingText、不动 messages 列表,故不会引入多余重建。
  List<LocalMessage> _lastMessages = const [];
  bool _initSync = true;
  bool _atBottom = true;
  bool _showAttach = false;
  // While the attachment panel animates open/closed, the chat viewport resizes
  // and the scroll extent shifts. Re-pin to the bottom through that resize so
  // the latest bubble stays visible (rises above the panel) instead of being
  // covered — otherwise the content only jumps on close.
  bool _pinBottomOnResize = false;
  bool _loadingMore = false;
  // Mirrors the provider's _hasMoreHistory so we don't re-query (and flash the
  // spinner) once older history is exhausted. Reset when the list reloads.
  bool _noMoreHistory = false;
  bool _firstLoad = true;
  // 流式输出"在场"标志:仅当 streamingText 在 null↔非null 之间翻转时才
  // 重建整树(增删尾部流式 sliver 项);流式内容逐字变化只由尾部 Consumer
  // 订阅 select((s)=>s.streamingText) 单独重建,不重建历史列表。
  bool _streamingActive = false;
  bool _streamingThinkingActive = false;
  // History-load bookkeeping (distinguishes a prepend from a new append so we
  // don't falsely auto-scroll to the latest when older messages load).
  bool _loadingHistory = false;
  double _preLoadPixels = 0;
  double _preLoadMaxExtent = 0;
  // Custom scroll thumb with date indicator.
  bool _scrollBarVisible = false;
  bool _draggingThumb = false;
  double _scrollFraction = 0;
  Timer? _scrollBarHideTimer;
  double _bottomPad = 0;
  bool _isDark = false;

  // Voice recording state
  bool _recording = false;
  double _recAmplitude = 0;
  bool _recCancel = false;
  late final AudioService _audioService;
  StreamSubscription<Amplitude>? _recSub;

  @override
  void initState() {
    super.initState();
    _audioService = AudioService(ref.read(permissionProvider));
    _scrollCtrl.addListener(() {
      if (!_scrollCtrl.hasClients) return;
      final pos = _scrollCtrl.position;
      final at = pos.pixels >= pos.maxScrollExtent - 100;
      if (at != _atBottom) setState(() => _atBottom = at);
      _onUserScroll();
    });
    _inputCtrl.addListener(() => setState(() {}));
    Future.microtask(() {
      ref.read(chatProvider.notifier).connect();
      ref.read(chatProvider.notifier).attachPlayback(ref.read(audioPlaybackProvider.notifier));
      // Keep the process alive in the background so the chat connection
      // persists and messages are not lost. 桌面经 DesktopKeepAlive no-op。
      () async {
        final ka = ref.read(keepAliveProvider);
        await ka.init();
        await ka.start();
      }();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bottomPad = MediaQuery.of(context).padding.bottom;
    _isDark = Theme.of(context).brightness == Brightness.dark;
  }

  @override
  Widget build(BuildContext context) {
    // --- Keyboard detection: scroll to bottom when keyboard opens ---
    final viewBottom = MediaQuery.of(context).viewInsets.bottom;
    if (viewBottom > 0 && _atBottom && _scrollCtrl.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients && _scrollCtrl.position.maxScrollExtent > 0) {
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
        }
      });
    }

    if (_initSync) {
      _initSync = false;
      final s = ref.read(chatProvider);
      _state = s; _lastLen = s.messages.length;
      _lastConn = s.connectionState; _lastMessages = s.messages;
      _streamingActive = s.streamingText != null;
      _streamingThinkingActive = s.streamingThinking != null;
    }
    ref.listen(chatProvider, (_, n) {
      // 流式内容逐字变化(n.streamingText/streamingThinking)不走 setState,交给尾部 Consumer
      // 自行重建;此处只在结构/状态变化或流式"在场"翻转时重建整树。
      final streamingToggled = (n.streamingText != null) != _streamingActive;
      final thinkingToggled = (n.streamingThinking != null) != _streamingThinkingActive;
      final needsRebuild = n.messages.length != _lastLen ||
          n.connectionState != _lastConn ||
          n.errorMessage != _state.errorMessage ||
          n.autoPlayVoice != _state.autoPlayVoice ||
          n.currentAccountName != _state.currentAccountName ||
          streamingToggled ||
          thinkingToggled ||
          !identical(n.messages, _lastMessages);

      final prevLen = _lastLen;
      _streamingActive = n.streamingText != null;
      _streamingThinkingActive = n.streamingThinking != null;
      _lastConn = n.connectionState; _lastMessages = n.messages;
      // A shrink (e.g. reconnect reloading the latest 10) means history was
      // re-armed on the provider side — clear our exhaustion flag too.
      if (n.messages.length < _lastLen) _noMoreHistory = false;
      _lastLen = n.messages.length;

      if (!needsRebuild) { _state = n; return; }

      final wasAtBottom = _atBottom;
      final isFirst = _firstLoad && n.messages.isNotEmpty;
      final grew = n.messages.length > prevLen;
      final historyLoad = _loadingHistory && grew;
      if (_firstLoad && n.messages.isNotEmpty) _firstLoad = false;
      _state = n;
      setState(() {});
      if (historyLoad) {
        // Older messages were prepended: keep the current view anchored by
        // shifting the offset by the amount the content grew at the top.
        _loadingHistory = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollCtrl.hasClients) return;
          final maxExtent = _scrollCtrl.position.maxScrollExtent;
          final target = (_preLoadPixels + (maxExtent - _preLoadMaxExtent))
              .clamp(0.0, maxExtent);
          _scrollCtrl.jumpTo(target);
        });
      } else if (isFirst || grew || (wasAtBottom && n.streamingText != null)) {
        if (isFirst) {
          // 全量加载历史首屏:长列表需追平懒布局后落到底部。
          _settleToBottom();
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd(jump: grew));
        }
      }
    });

    final w = MediaQuery.of(context).size.width;
    _w = w;
    final isDark = _isDark;
    final conn = _state.connectionState == ConnState.connected;
    final n = _itemCount();

    return Scaffold(
      resizeToAvoidBottomInset: true,
      drawer: const AccountDrawer(),
      backgroundColor: isDark ? const Color(0xFF0F0F0F) : const Color(0xFFFAFAFB),
      appBar: _Bar(
        conn: conn, isDark: isDark, error: _state.errorMessage,
        accountName: _state.currentAccountName,
        streaming: _state.streamingText?.isNotEmpty == true,
        reconnecting: _state.connectionState == ConnState.reconnecting,
        autoPlay: _state.autoPlayVoice,
        onToggleAutoPlay: () => ref.read(chatProvider.notifier).setAutoPlayVoice(!_state.autoPlayVoice),
      ),
      body: Column(children: [
        Expanded(child: n == 0
          ? const Center(child: Text('发送消息开始聊天', style: TextStyle(color: Color(0xFF999999), fontSize: 14)))
          : Stack(children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: isDark
                            ? [const Color(0xFF151518), const Color(0xFF0B0B0D)]
                            : [const Color(0xFFFBFBFD), const Color(0xFFF3F4F8)],
                      ),
                    ),
                  ),
                ),
              ),
              NotificationListener<ScrollMetricsNotification>(
                onNotification: (_) {
                  // Viewport resized (panel animating in/out). Re-pin to the
                  // bottom so the latest bubble tracks the panel edge.
                  if (_pinBottomOnResize && _scrollCtrl.hasClients) {
                    final pos = _scrollCtrl.position;
                    if (pos.maxScrollExtent > 0) _scrollCtrl.jumpTo(pos.maxScrollExtent);
                  }
                  return false;
                },
                child: NotificationListener<ScrollEndNotification>(
                  onNotification: (_) {
                    _maybeLoadMore();
                    return false;
                  },
                  child: CustomScrollView(
                    controller: _scrollCtrl,
                    physics: const ClampingScrollPhysics(),
                    slivers: [
                      if (_loadingMore)
                        const SliverToBoxAdapter(child: SizedBox(height: 36, child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))))),
                      const SliverPadding(padding: EdgeInsets.only(top: 8)),
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (ctx, i) => RepaintBoundary(child: _item(i)),
                          childCount: n,
                        ),
                      ),
                      SliverPadding(padding: EdgeInsets.only(bottom: 80 + _bottomPad)),
                    ],
                  ),
                ),
              ),
              if (!_atBottom && n > 0)
                Positioned(right: 12, bottom: 8,
                  child: _FAB(isDark: isDark, onTap: _jumpToBottom)),
              if (n > 0 && (_scrollBarVisible || _draggingThumb))
                _ScrollThumbOverlay(
                  fraction: _scrollFraction,
                  isDark: isDark,
                  dateLabel: _dateAtFraction(),
                  showDate: _draggingThumb,
                  onDrag: _onThumbDrag,
                  onDragEnd: _onThumbDragEnd,
                ),
            ]),
        ),
        // Recording overlay
        if (_recording) _VoiceOverlay(amplitude: _recAmplitude, isCancel: _recCancel, isDark: isDark),
        // Inline attachment panel
        AnimatedSize(duration: const Duration(milliseconds: 200), curve: Curves.easeInOut, child:
          _showAttach ? AttachmentPanel(
            onClose: () => setState(() => _showAttach = false),
            onPickImage: _sendImage,
            onPickFile: _sendFile,
          ) : const SizedBox.shrink(),
        ),
        _InputBar(send: _send, ctrl: _inputCtrl, focus: _focusNode, isDark: isDark,
          hasText: _inputCtrl.text.isNotEmpty,
          showAttachment: _toggleAttach,
          slashMatches: _slashMatches,
          onPickSlash: _pickSlashCommand,
          onVoiceStart: _startVoice, onVoiceMove: _voiceMove, onVoiceEnd: _endVoice),
      ]),
    );
  }

  void _scrollToEnd({bool jump = false}) {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.maxScrollExtent <= 0) return;
    if (jump) {
      _scrollCtrl.jumpTo(pos.maxScrollExtent);
    } else {
      _scrollCtrl.animateTo(pos.maxScrollExtent,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  /// Reliably jump to the latest message (used by the FAB). A plain animateTo
  /// can stop short on very long lazy lists because maxScrollExtent is read
  /// before off-screen slivers are laid out; jumping in a post-frame callback
  /// after layout guarantees reaching the true bottom.
  void _jumpToBottom() {
    _settleToBottom();
  }

  /// 置底并"追平"懒布局:长列表(加载全部历史时)首屏 maxScrollExtent 是
  /// 估算值,jumpTo 一次只能到当前估算的底,随着更多离屏 sliver 布局,
  /// maxScrollExtent 会继续增长。这里每帧检查:若 extent 仍在增长就再跳一次,
  /// 直到稳定或达上限(8 帧),保证真正落到最新消息。
  void _settleToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _settleStep(0));
  }

  void _settleStep(int n) {
    if (!mounted || !_scrollCtrl.hasClients || n > 8) return;
    final pos = _scrollCtrl.position;
    if (pos.maxScrollExtent <= 0) return;
    final prevExtent = pos.maxScrollExtent;
    _scrollCtrl.jumpTo(pos.maxScrollExtent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      final p = _scrollCtrl.position;
      // extent 仍在增长 → 懒布局尚未追平,下一帧再跳。
      if (p.maxScrollExtent > prevExtent + 1) _settleStep(n + 1);
    });
  }

  /// Toggle the attachment panel. While the panel animates open or closed the
  /// chat viewport resizes; if we're at the bottom, re-pin to the bottom
  /// throughout the resize (via ScrollMetricsNotification) so the latest bubble
  /// rises above the opening panel instead of being covered, and settles
  /// smoothly on close.
  void _toggleAttach() {
    final willShow = !_showAttach;
    final pin = _atBottom;
    setState(() => _showAttach = willShow);
    if (pin) {
      _pinBottomOnResize = true;
      Future.delayed(const Duration(milliseconds: 260), () {
        if (mounted) _pinBottomOnResize = false;
      });
    }
  }

  // --- Custom scroll thumb with date indicator ---
  /// Load older history when the user finishes a scroll pinned to the very top
  /// of a scrollable list. Triggering on ScrollEnd (instead of a raw
  /// position-pixels threshold) avoids spurious/infinite loads: programmatic
  /// jumps to the latest and short (non-scrollable) lists no longer fire it,
  /// and after a load the anchor jump leaves the offset away from the top so it
  /// never re-enters.
  void _maybeLoadMore() {
    if (_loadingMore || _noMoreHistory || !_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.maxScrollExtent <= 0) return; // list not scrollable yet
    if (pos.pixels > pos.minScrollExtent + 2) return; // not pinned to the top
    _loadingMore = true;
    // Mark this as a history load so the state listener does not mistake the
    // growing message list for new messages and jump to the latest.
    _loadingHistory = true;
    _preLoadPixels = pos.pixels;
    _preLoadMaxExtent = pos.maxScrollExtent;
    ref.read(chatProvider.notifier).loadMoreHistory().then((added) {
      if (!mounted) return;
      if (!added) _noMoreHistory = true; // exhausted: stop re-querying
      setState(() => _loadingMore = false);
      _loadingHistory = false; // safety reset if no state change happened
    });
  }

  void _onUserScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    final max = pos.maxScrollExtent <= 0 ? 1.0 : pos.maxScrollExtent;
    _scrollFraction = (pos.pixels / max).clamp(0.0, 1.0);
    if (!_scrollBarVisible) setState(() => _scrollBarVisible = true);
    _scrollBarHideTimer?.cancel();
    _scrollBarHideTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted && !_draggingThumb) setState(() => _scrollBarVisible = false);
    });
  }

  String? _dateAtFraction() {
    final msgs = _state.messages;
    if (msgs.isEmpty) return null;
    final idx = (_scrollFraction * (msgs.length - 1)).round().clamp(0, msgs.length - 1);
    return _dateLabel(msgs[idx].createdAt);
  }

  void _onThumbDrag(double frac) {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    final max = pos.maxScrollExtent;
    if (max <= 0) return;
    _scrollFraction = frac;
    _scrollCtrl.jumpTo(frac * max);
    if (!_draggingThumb) setState(() => _draggingThumb = true);
    setState(() {}); // refresh the date bubble while dragging
  }

  void _onThumbDragEnd() {
    if (_draggingThumb) setState(() => _draggingThumb = false);
    _scrollBarHideTimer?.cancel();
    _scrollBarHideTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _scrollBarVisible = false);
    });
  }

  int _itemCount() => _state.messages.length +
      ((_state.streamingThinking?.isNotEmpty == true) ? 1 : 0) +
      ((_state.streamingText?.isNotEmpty == true) ? 1 : 0);

  Widget _item(int i) {
    final msgs = _state.messages;
    if (i < msgs.length) {
      final m = msgs[i];
      // thinking / tool_status：渲染为内联系统块（非聊天气泡），与实时一致。
      if (m.msgType == 'thinking') {
        return _ThinkingBlock(text: m.content ?? '', isDark: _isDark);
      }
      if (m.msgType == 'tool_status') {
        return _ToolStatus(text: m.content ?? '');
      }
      // Date divider when the day changes (or on the first message).
      final curDay = _dayKey(m.createdAt);
      final prevDay = i == 0 ? null : _dayKey(msgs[i - 1].createdAt);
      final showDate = prevDay != curDay;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDate) _DateDivider(label: _dateLabel(m.createdAt), isDark: _isDark),
          _Bubble(m: m, bw: _w - 48, isDark: _isDark),
        ],
      );
    }
    int j = i - msgs.length;
    if (j == 0 && _state.streamingThinking?.isNotEmpty == true) {
      return _ThinkingBlock(text: _state.streamingThinking!, isDark: _isDark);
    }
    return Consumer(builder: (ctx, ref, _) {
      final st = ref.watch(chatProvider.select((s) => s.streamingText)) ?? '';
      return _Streaming(text: st, bw: _w - 48, isDark: _isDark);
    });
  }

  static DateTime _dayKey(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    return DateTime(d.year, d.month, d.day);
  }

  static String _dateLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    final today = DateTime.now();
    final day = DateTime(d.year, d.month, d.day);
    final now = DateTime(today.year, today.month, today.day);
    final diff = now.difference(day).inDays;
    if (diff <= 0) return '今天';
    if (diff == 1) return '昨天';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  void _send() {
    final t = _inputCtrl.text.trim();
    if (t.isEmpty) return;
    _inputCtrl.clear();
    _focusNode.requestFocus();
    _showAttach = false;
    ref.read(chatProvider.notifier).sendText(t);
  }

  // --- Voice recording ---
  Future<void> _startVoice() async {
    final ok = await _audioService.hasPermission();
    if (!ok) return;
    await _audioService.startRecording();
    setState(() { _recording = true; _recCancel = false; _recAmplitude = 0; });
    ref.read(audioProvider.notifier).startRecording();
    _recSub = _audioService.amplitudeStream(const Duration(milliseconds: 100)).listen((amp) {
      if (mounted) setState(() => _recAmplitude = ((amp.current + 60) / 60).clamp(0.0, 1.0));
    });
  }

  void _voiceMove(double dy) {
    if (_recording) setState(() => _recCancel = dy < -60);
  }

  Future<void> _endVoice() async {
    _recSub?.cancel();
    final file = await _audioService.stopRecording();
    ref.read(audioProvider.notifier).stopRecording();
    final cancel = _recCancel;
    setState(() { _recording = false; _recCancel = false; });
    if (cancel || file == null) return;

    final notifier = ref.read(chatProvider.notifier);
    final key = notifier
        .createPendingMedia(msgType: 'voice', localPath: file.path);
    final id = await notifier.uploadMedia(file, 'audio/wav', onProgress: (s, t) {
      notifier.updateUploadProgress(key, t > 0 ? s / t : 0);
    });
    if (id != null && mounted) {
      notifier.finalizeMediaSend(key, id, 'voice');
    } else if (mounted) {
      notifier.failMediaUpload(key);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('语音发送失败'), backgroundColor: Colors.redAccent));
    }
  }

  Future<void> _sendImage(File file) async {
    final notifier = ref.read(chatProvider.notifier);
    final key = notifier
        .createPendingMedia(msgType: 'image', localPath: file.path);
    final id = await notifier.uploadMedia(file, 'image/jpeg', onProgress: (s, t) {
      notifier.updateUploadProgress(key, t > 0 ? s / t : 0);
    });
    if (id != null && mounted) {
      notifier.finalizeMediaSend(key, id, 'image');
    } else if (mounted) {
      notifier.failMediaUpload(key);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('图片上传失败'), backgroundColor: Colors.redAccent));
    }
  }

  Future<void> _sendFile(File file, String filename, String mime) async {
    final notifier = ref.read(chatProvider.notifier);
    final key = notifier
        .createPendingMedia(msgType: 'file', localPath: file.path, content: filename);
    final id = await notifier.uploadMedia(file, mime, onProgress: (s, t) {
      notifier.updateUploadProgress(key, t > 0 ? s / t : 0);
    });
    if (id != null && mounted) {
      notifier.finalizeMediaSend(key, id, 'file');
    } else if (mounted) {
      notifier.failMediaUpload(key);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件上传失败'), backgroundColor: Colors.redAccent));
    }
  }

  @override void dispose() {
    _scrollCtrl.dispose(); _inputCtrl.dispose(); _focusNode.dispose();
    _recSub?.cancel(); _audioService.dispose();
    _scrollBarHideTimer?.cancel();
    super.dispose();
  }
}

// ====== VOICE RECORDING OVERLAY ======
class _VoiceOverlay extends StatefulWidget {
  final double amplitude; final bool isCancel; final bool isDark;
  const _VoiceOverlay({required this.amplitude, required this.isCancel, required this.isDark});
  @override State<_VoiceOverlay> createState() => _VoiceOverlayState();
}

class _VoiceOverlayState extends State<_VoiceOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final Stopwatch _sw = Stopwatch();

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
    _sw.start();
  }

  @override
  void dispose() { _ctrl.dispose(); _sw.stop(); super.dispose(); }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext ctx) {
    final cancel = widget.isCancel;
    final accent = cancel ? Colors.redAccent : const Color(0xFF5B4BD6);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final t = _ctrl.value; // 0..1 looping -> drives the wave phase
        // Overall scale from input amplitude (baseline so bars stay visible when silent).
        final amp = (widget.amplitude.clamp(0.0, 1.0)) * 0.75 + 0.20;
        return Container(
          height: 60,
          decoration: BoxDecoration(
            color: widget.isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF7F7F8),
            border: Border(top: BorderSide(
                color: widget.isDark ? const Color(0xFF3A3A3C) : const Color(0xFFE0E0E5), width: 0.5)),
          ),
          child: SafeArea(top: false, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [accent, accent.withValues(alpha: 0.65)]),
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 8, spreadRadius: 0.5)],
                ),
                child: Icon(cancel ? Icons.delete_outline : Icons.mic_rounded, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 12),
              SizedBox(height: 30, child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center,
                children: List.generate(5, (i) {
                  final phase = t * 2 * pi + i * 0.6;
                  final wave = 0.5 + 0.5 * sin(phase); // 0..1
                  final h = (8 + wave * 20 * amp).clamp(6.0, 28.0);
                  return Padding(padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Container(width: 5, height: h,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter,
                          colors: [accent.withValues(alpha: 0.5), accent]),
                        borderRadius: BorderRadius.circular(3))));
                }),
              )),
              const SizedBox(width: 12),
              Text(_fmt(_sw.elapsed),
                style: TextStyle(color: widget.isDark ? Colors.white : const Color(0xFF333333),
                    fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(cancel ? '松开取消' : '上划取消',
                style: TextStyle(color: cancel ? Colors.redAccent : (widget.isDark ? Colors.white54 : const Color(0xFF9E9E9E)), fontSize: 12)),
            ]),
          )),
        );
      },
    );
  }
}

// ====== FAB ======
class _FAB extends StatelessWidget {
  final bool isDark; final VoidCallback onTap;
  const _FAB({required this.isDark, required this.onTap});
  @override
  Widget build(BuildContext ctx) => Material(
    color: isDark ? const Color(0xFF3A3A3C) : Colors.white,
    borderRadius: BorderRadius.circular(20), elevation: 4,
    child: InkWell(borderRadius: BorderRadius.circular(20), onTap: onTap,
      child: Container(padding: const EdgeInsets.all(10),
        child: Icon(Icons.keyboard_arrow_down_rounded, color: isDark ? Colors.white : Colors.black, size: 22))),
  );
}

// ====== BUBBLE ======
class _Bubble extends StatelessWidget {
  final dynamic m; final double bw; final bool isDark;
  const _Bubble({required this.m, required this.bw, required this.isDark});
  @override
  Widget build(BuildContext ctx) {
    final isMe = (m.isFromMe as bool?) ?? false;
    final type = (m.msgType as String?) ?? 'text';
    final text = (m.content as String?) ?? '';
    final bg = isMe
        ? (isDark ? const Color(0xFF7661D8) : const Color(0xFF5B4BD6))
        : (isDark ? const Color(0xFF212121) : const Color(0xFFE8E8EC));
    final fg = isMe ? Colors.white : (isDark ? Colors.white : Colors.black);

    Widget body;
    switch (type) {
      case 'image':
        body = _ImageBubble(m: m, bw: bw, isMe: isMe);
        break;
      case 'voice':
      case 'record':
      case 'audio':
        body = _VoiceBubble(m: m, fg: fg, isMe: isMe);
        break;
      case 'file':
        body = _FileBubble(m: m, fg: fg, isMe: isMe);
        break;
      default:
        final errored = (m.status as MessageStatus?) == MessageStatus.error;
        body = errored
            ? _TextBodyError(content: text, createdAt: (m.createdAt as int?) ?? 0)
            : _mdText(text, fg, isDark);
    }

    final createdAt = (m.createdAt as int?) ?? 0;
    final time = createdAt > 0 ? _hhmm(createdAt) : null;
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, bottom: 3),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: bw),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: isMe
                      ? const BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16), bottomLeft: Radius.circular(16), bottomRight: Radius.circular(2))
                      : const BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16), bottomLeft: Radius.circular(2), bottomRight: Radius.circular(16)),
                ),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: body),
              ),
            ),
          ),
          if (time != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 4, right: 4, bottom: 6),
              child: Text(time, style: TextStyle(fontSize: 10, color: isDark ? const Color(0xFF8E8E93) : const Color(0xFF9E9E9E))),
            ),
        ],
      ),
    );
  }

  static String _hhmm(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  static Widget _mdText(String text, Color fg, bool isDark) {
    if (text.isEmpty) return const SizedBox.shrink();
    if (!_hasMarkdown(text)) {
      return SelectableText(text, style: TextStyle(color: fg, fontSize: 16, height: 1.35));
    }
    // SelectionArea enables long-press selection / segment copy across the
    // markdown-rendered Text spans.
    return SelectionArea(child: _MarkdownContent(text: text, fg: fg, isDark: isDark));
  }

  static bool _hasMarkdown(String t) {
    for (int i = 0; i < t.length; i++) {
      final c = t.codeUnitAt(i);
      if (c == 0x2A || c == 0x5F || c == 0x60 || c == 0x7E || c == 0x23 || c == 0x7C || c == 0x3E || c == 0x5B) return true;
    }
    return false;
  }
}

/// 文本气泡发送失败态:点击重发(复用 retryTextSend,与媒体失败态对称)。
class _TextBodyError extends ConsumerWidget {
  final String content;
  final int createdAt;
  const _TextBodyError({required this.content, required this.createdAt});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => ref.read(chatProvider.notifier).retryTextSend(createdAt),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 16),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            content,
            style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 15,
                height: 1.35,
                decoration: TextDecoration.lineThrough),
          ),
        ),
        const SizedBox(width: 6),
        const Icon(Icons.refresh_rounded, color: Colors.redAccent, size: 16),
      ]),
    );
  }
}

// ====== SCROLL THUMB + DATE OVERLAY ======
class _ScrollThumbOverlay extends StatelessWidget {
  final double fraction; // 0..1 of scroll position
  final bool isDark;
  final String? dateLabel;
  final bool showDate;
  final void Function(double frac)? onDrag;
  final VoidCallback? onDragEnd;

  const _ScrollThumbOverlay({
    required this.fraction,
    required this.isDark,
    required this.dateLabel,
    required this.showDate,
    this.onDrag,
    this.onDragEnd,
  });

  @override
  Widget build(BuildContext ctx) {
    return LayoutBuilder(builder: (ctx, c) {
      final trackHeight = c.maxHeight;
      final thumbHeight = (trackHeight * 0.22).clamp(42.0, 130.0);
      final clampedFrac = fraction.clamp(0.0, 1.0);
      final thumbTop = (clampedFrac * (trackHeight - thumbHeight))
          .clamp(0.0, (trackHeight - thumbHeight).clamp(1.0, double.infinity));
      final thumbColor = isDark ? const Color(0xFFB0B0B5) : const Color(0xFF8A8A8E);

      return Stack(fit: StackFit.expand, children: [
        // Centered date indicator shown while dragging the thumb.
        if (showDate && dateLabel != null)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2A2A2E) : Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 10, offset: const Offset(0, 2)),
                ],
              ),
              child: Text(
                dateLabel!,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF1C1C1E),
                ),
              ),
            ),
          ),
        // Draggable thumb on the right edge.
        Positioned(
          right: 3,
          top: thumbTop,
          width: 26,
          height: thumbHeight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) {
              final h = trackHeight <= 0 ? 1.0 : trackHeight;
              final frac = (d.localPosition.dy / h).clamp(0.0, 1.0);
              onDrag?.call(frac);
            },
            onVerticalDragEnd: (_) => onDragEnd?.call(),
            child: Center(
              child: Container(
                width: 4,
                height: thumbHeight * 0.6,
                decoration: BoxDecoration(
                  color: thumbColor.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ]);
    });
  }
}

// ====== DATE DIVIDER ======
class _DateDivider extends StatelessWidget {
  final String label;
  final bool isDark;
  const _DateDivider({required this.label, required this.isDark});
  @override
  Widget build(BuildContext ctx) {
    final fg = isDark ? const Color(0xFF8E8E93) : const Color(0xFF8A8A8E);
    final bg = isDark ? const Color(0xFF2A2A2E) : const Color(0xFFE8E8EC);
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        child: Text(label, style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w500)),
      ),
    );
  }
}

// ====== UPLOAD BADGE (circular % shown while sending media) ======
class _UploadBadge extends StatelessWidget {
  final double progress; // 0..1
  const _UploadBadge({required this.progress});
  @override
  Widget build(BuildContext ctx) {
    final pct = (progress.clamp(0.0, 1.0) * 100).round();
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(width: 30, height: 30, child: CircularProgressIndicator(
        value: progress > 0 ? progress : null,
        strokeWidth: 3,
        valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
        backgroundColor: Colors.white.withValues(alpha: 0.25),
      )),
      const SizedBox(height: 4),
      Text('$pct%', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
    ]);
  }
}

// ====== IMAGE BUBBLE ======
class _ImageBubble extends ConsumerStatefulWidget {
  final dynamic m; final double bw; final bool isMe;
  const _ImageBubble({required this.m, required this.bw, required this.isMe, super.key});
  @override ConsumerState<_ImageBubble> createState() => _ImageBubbleState();
}
class _ImageBubbleState extends ConsumerState<_ImageBubble> {
  String? _downloaded;
  bool _loading = false;

  @override void initState() {
    super.initState();
    final lp = (widget.m.localPath as String?) ?? '';
    if (lp.isNotEmpty) {
      _downloaded = lp;
    } else if (!widget.isMe) {
      // botapi: provider 在收到事件时已下载媒体到 localPath。
      // 此处占位 loading，等 didUpdateWidget 带回 localPath。
      _loading = true;
    }
  }

  @override
  void didUpdateWidget(covariant _ImageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // provider 下载完成后把 localPath 贴到消息上。
    if (_downloaded == null && !widget.isMe) {
      final lp = (widget.m.localPath as String?) ?? '';
      if (lp.isNotEmpty && lp != (oldWidget.m.localPath as String?) && _loading) {
        setState(() { _downloaded = lp; _loading = false; });
      }
    }
  }

  void _openFullScreen() {
    if (_downloaded == null) return;
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black87,
      barrierDismissible: true,
      pageBuilder: (_, __, ___) => _FullScreenImage(path: _downloaded!),
    ));
  }

  @override Widget build(BuildContext ctx) {
    final w = (widget.bw * 0.6).clamp(120.0, 200.0);
    final uploading = (widget.m.status as MessageStatus?) == MessageStatus.uploading;
    final prog = (widget.m.uploadProgress as double?) ?? 0;
    if (_downloaded != null) {
      return GestureDetector(
        onTap: uploading ? null : _openFullScreen,
        child: Stack(children: [
          ClipRRect(borderRadius: BorderRadius.circular(12),
              child: Image.file(File(_downloaded!), width: w, fit: BoxFit.cover)),
          if (uploading)
            Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(12),
                child: Container(color: Colors.black.withValues(alpha: 0.45),
                    child: Center(child: _UploadBadge(progress: prog))))),
        ]),
      );
    }
    final errored = (widget.m.status as MessageStatus?) == MessageStatus.error;
    // 占位图标需按气泡背景取色:我发出(紫底)用半透明白;对方(灰底,下载中)用紫色强调,
    // 否则 white54 在浅灰对方气泡上几乎不可见。
    final placeholderColor =
        widget.isMe ? Colors.white54 : const Color(0xFF5B4BD6);
    return SizedBox(
      width: w, height: w * 0.6,
      child: errored
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => ref.read(chatProvider.notifier).retryMediaSend(
                  (widget.m.createdAt as int), 'image',
                  (widget.m.localPath as String?), (widget.m.content as String?)),
              child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.refresh_rounded, color: Colors.redAccent, size: 30),
                const SizedBox(height: 6),
                Text('发送失败,点击重试', style: TextStyle(color: Colors.redAccent.shade100, fontSize: 12)),
              ])))
          : (uploading
              ? Center(child: _UploadBadge(progress: prog))
              : (_loading
                  ? Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(
                      strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(placeholderColor))))
                  : Icon(Icons.image, size: 48, color: placeholderColor))),
    );
  }
}

// ====== FULLSCREEN IMAGE VIEWER ======
class _FullScreenImage extends StatelessWidget {
  final String path;
  const _FullScreenImage({required this.path});
  @override
  Widget build(BuildContext ctx) => Scaffold(
    backgroundColor: Colors.transparent,
    body: GestureDetector(
      onTap: () => Navigator.of(ctx).pop(),
      child: Center(
        child: InteractiveViewer(
          maxScale: 5.0,
          child: Image.file(File(path)),
        ),
      ),
    ),
  );
}

// ====== VOICE BUBBLE ======
class _VoiceBubble extends ConsumerStatefulWidget {
  final dynamic m; final Color fg; final bool isMe;
  const _VoiceBubble({required this.m, required this.fg, required this.isMe, super.key});
  @override ConsumerState<_VoiceBubble> createState() => _VoiceBubbleState();
}
class _VoiceBubbleState extends ConsumerState<_VoiceBubble> {
  String get _key => messageKey(widget.m as LocalMessage);

  @override Widget build(BuildContext ctx) {
    final fg = widget.fg;
    final accent = const Color(0xFF5B4BD6);
    // 我发出的气泡是紫色:播放控件用白色系保证对比度;对方气泡(浅/深灰)用紫色强调。
    final onBubble = widget.isMe ? Colors.white : accent;
    final m = widget.m as LocalMessage;
    final pb = ref.watch(audioPlaybackProvider);
    final player = ref.read(audioPlaybackProvider.notifier);

    // 上传中:走旧的上传进度行,不进播放 service
    if (m.status == MessageStatus.uploading) {
      final prog = m.uploadProgress ?? 0;
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 30, height: 30, alignment: Alignment.center,
          decoration: BoxDecoration(color: onBubble.withValues(alpha: widget.isMe ? 0.25 : 0.12), borderRadius: BorderRadius.circular(8)),
          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(
            value: prog > 0 ? prog : null, strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(onBubble)))),
        const SizedBox(width: 10),
        Text('语音上传中 ${(prog * 100).round()}%', style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w500)),
      ]);
    }

    // 发送失败:点击重发(复用 localPath 重新上传)。
    if (m.status == MessageStatus.error) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(chatProvider.notifier)
            .retryMediaSend(m.createdAt, m.msgType, m.localPath, m.content),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 30, height: 30, alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.refresh_rounded, color: Colors.redAccent, size: 18)),
          const SizedBox(width: 10),
          Text('发送失败,点击重试', style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w500)),
        ]),
      );
    }

    final loading = pb.isLoading(_key);
    final playing = pb.isPlaying(_key);
    final active = pb.currentKey == _key; // 当前播放/暂停的就是本条
    // 只有 active 气泡才显示全局播放进度;非 active 气泡进度归零,
    // 否则它们会跟着当前播放条的 position/duration 一起动(视觉串台)。
    final max = active
        ? pb.duration.inMilliseconds.toDouble().clamp(1.0, double.infinity)
        : 1.0;
    final val = active
        ? pb.position.inMilliseconds.toDouble().clamp(0.0, max)
        : 0.0;

    String timeText(Duration d) {
      final s = d.inSeconds.abs();
      return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (loading)
        const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
      else GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => player.toggle(m),
        child: Container(
          width: 30, height: 30, alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? onBubble : onBubble.withValues(alpha: widget.isMe ? 0.25 : 0.14)),
          child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: active ? (widget.isMe ? accent : Colors.white) : onBubble, size: 18))),
      const SizedBox(width: 8),
      SizedBox(
        width: 76,
        child: SliderTheme(
          data: SliderThemeData(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            activeTrackColor: onBubble,
            inactiveTrackColor: fg.withValues(alpha: 0.3),
            thumbColor: onBubble,
          ),
          child: Slider(
            value: val,
            min: 0,
            max: max,
            onChanged: active ? (v) => player.seek(Duration(milliseconds: v.round())) : null,
            onChangeEnd: active ? (v) => player.seek(Duration(milliseconds: v.round())) : null,
          ),
        ),
      ),
      const SizedBox(width: 4),
      SizedBox(width: 38,
        child: Text(timeText(active ? pb.position : Duration.zero), style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 11))),
      if (active) ...[
        const SizedBox(width: 2),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => player.stop(),
          child: Icon(Icons.stop_rounded, color: fg.withValues(alpha: 0.8), size: 20)),
      ],
    ]);
  }
}

// ====== FILE BUBBLE ======
class _FileBubble extends ConsumerStatefulWidget {
  final dynamic m; final Color fg; final bool isMe;
  const _FileBubble({required this.m, required this.fg, required this.isMe, super.key});
  @override ConsumerState<_FileBubble> createState() => _FileBubbleState();
}
class _FileBubbleState extends ConsumerState<_FileBubble> {
  bool _downloading = false;

  void _retry() {
    ref.read(chatProvider.notifier).retryMediaSend(
        (widget.m.createdAt as int), (widget.m.msgType as String),
        (widget.m.localPath as String?), (widget.m.content as String?));
  }

  Future<void> _open() async {
    final name = (widget.m.content as String?) ?? 'file';
    setState(() => _downloading = true);
    try {
      // botapi: 媒体在收到事件时已由 provider 下载到 localPath（单次有效 URL，无法重取）。
      File? src;
      final lp = (widget.m.localPath as String?) ?? '';
      if (lp.isNotEmpty && File(lp).existsSync()) {
        src = File(lp);
      }
      if (src == null || !await src.exists()) throw Exception('文件未缓存（可能已过期）');
      // Copy to a temp path that keeps the real filename (so apps recognize the type),
      // then let the user choose which application opens it via the system share sheet.
      final safe = name.replaceAll(RegExp(r'[/\\]'), '_');
      final tmp = await getTemporaryDirectory();
      final dest = File('${tmp.path}/astrbot_$safe');
      await dest.writeAsBytes(await src.readAsBytes());
      await Share.shareXFiles([XFile(dest.path, name: name, mimeType: _mimeForName(name))]);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开失败: $e'), backgroundColor: Colors.redAccent));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  static String _mimeForName(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'jpg': case 'jpeg': return 'image/jpeg';
      case 'png': return 'image/png';
      case 'gif': return 'image/gif';
      case 'webp': return 'image/webp';
      case 'pdf': return 'application/pdf';
      case 'txt': return 'text/plain';
      case 'mp4': return 'video/mp4';
      case 'mp3': return 'audio/mpeg';
      case 'wav': return 'audio/wav';
      case 'doc': return 'application/msword';
      case 'docx': return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls': return 'application/vnd.ms-excel';
      case 'xlsx': return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'zip': return 'application/zip';
      default: return 'application/octet-stream';
    }
  }

  @override Widget build(BuildContext ctx) {
    final fg = widget.fg;
    final name = (widget.m.content as String?) ?? '文件';
    final uploading = (widget.m.status as MessageStatus?) == MessageStatus.uploading;
    final errored = (widget.m.status as MessageStatus?) == MessageStatus.error;
    final prog = (widget.m.uploadProgress as double?) ?? 0;
    final accent = const Color(0xFF5B4BD6);
    // 我发出的气泡是紫色:文件图标用白色系保证对比度;对方气泡(灰)用紫色强调。
    final onBubble = widget.isMe ? Colors.white : accent;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: uploading ? null : (errored ? _retry : _open),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 34, height: 34, alignment: Alignment.center,
              decoration: BoxDecoration(color: errored
                  ? Colors.redAccent.withValues(alpha: 0.15)
                  : onBubble.withValues(alpha: widget.isMe ? 0.25 : 0.12), borderRadius: BorderRadius.circular(8)),
              child: uploading
                ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(
                    value: prog > 0 ? prog : null, strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(onBubble)))
                : (_downloading
                    ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(
                        strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(onBubble.withValues(alpha: 0.8))))
                    : Icon(errored ? Icons.refresh_rounded : Icons.description_rounded,
                        color: errored ? Colors.redAccent : onBubble, size: 18)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(name, style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
              const SizedBox(height: 1),
              Text(uploading
                  ? '上传中 ${(prog * 100).round()}%'
                  : (errored
                      ? '发送失败,点击重试'
                      : (_downloading ? '准备中…' : '点击打开')),
                  style: TextStyle(
                      color: errored ? Colors.redAccent : fg.withValues(alpha: 0.55),
                      fontSize: 11)),
            ])),
            if (!uploading)
              Icon(Icons.chevron_right_rounded, color: fg.withValues(alpha: 0.4), size: 18),
          ]),
          if (uploading) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: prog > 0 ? prog : null,
                minHeight: 3,
                backgroundColor: fg.withValues(alpha: 0.2),
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

// ====== MARKDOWN ======

/// 共享 markdown 样式表：最终气泡与流式渲染复用，保证视觉一致。
md.MarkdownStyleSheet _mdStyleSheet(Color fg, bool isDark) {
  return md.MarkdownStyleSheet(
    p: TextStyle(color: fg, fontSize: 16, height: 1.35),
    h1: TextStyle(color: fg, fontSize: 20, fontWeight: FontWeight.bold),
    h2: TextStyle(color: fg, fontSize: 18, fontWeight: FontWeight.bold),
    h3: TextStyle(color: fg, fontSize: 17, fontWeight: FontWeight.bold),
    a: TextStyle(color: const Color(0xFF4A8FE7), decoration: TextDecoration.underline, decorationColor: const Color(0xFF4A8FE7)),
    code: TextStyle(color: fg, fontSize: 14, fontFamily: 'monospace',
      backgroundColor: isDark ? const Color(0xFF3A3A3C) : const Color(0xFFE8E8EC)),
    codeblockDecoration: BoxDecoration(
      color: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7), borderRadius: BorderRadius.circular(8)),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: fg.withValues(alpha: 0.35), width: 3))),
    blockquotePadding: const EdgeInsets.only(left: 12),
    tableBorder: TableBorder.all(color: fg.withValues(alpha: 0.2), width: 0.5),
    tableHead: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 14),
    tableBody: TextStyle(color: fg, fontSize: 14),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: fg.withValues(alpha: 0.2)))),
    strong: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 16),
    em: TextStyle(color: fg, fontStyle: FontStyle.italic, fontSize: 16),
    listBullet: TextStyle(color: fg, fontSize: 16), listIndent: 16,
  );
}

/// 链接点击：仅放行 http/https，交给系统默认浏览器打开。
void _launchUrl(String text, String? href, String title) {
  final url = href ?? text;
  if (url.isEmpty) return;
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  if (uri.scheme != 'http' && uri.scheme != 'https') return;
  launchUrl(uri, mode: LaunchMode.externalApplication);
}

class _MarkdownContent extends StatefulWidget {
  final String text; final Color fg; final bool isDark;
  const _MarkdownContent({required this.text, required this.fg, required this.isDark, super.key});
  @override State<_MarkdownContent> createState() => _MarkdownContentState();
}
class _MarkdownContentState extends State<_MarkdownContent> {
  static final LruCache<String, Widget> _cache = LruCache(maxSize: 32);
  Widget? _built;

  @override void initState() { super.initState(); _build(); }

  @override void didUpdateWidget(covariant _MarkdownContent old) {
    super.didUpdateWidget(old);
    if (widget.text != old.text || widget.isDark != old.isDark) _build();
  }

  void _build() {
    final key = '${widget.isDark ? 'd' : 'l'}_${widget.text}';
    final cached = _cache[key];
    if (cached != null) { _built = cached; return; }
    Future.microtask(() {
      if (!mounted) return;
      final w = md.MarkdownBody(
        data: widget.text,
        selectable: false,
        styleSheet: _mdStyleSheet(widget.fg, widget.isDark),
        onTapLink: _launchUrl,
      );
      _cache[key] = w;
      if (mounted) setState(() => _built = w);
    });
  }

  @override Widget build(BuildContext ctx) => _built ?? Text(widget.text, style: TextStyle(color: widget.fg, fontSize: 16, height: 1.35));
}

// ====== STREAMING ======
class _Streaming extends StatelessWidget {
  final String text; final double bw; final bool isDark;
  const _Streaming({required this.text, required this.bw, required this.isDark});
  @override
  Widget build(BuildContext ctx) {
    final bg = isDark ? const Color(0xFF212121) : const Color(0xFFE8E8EC);
    final fg = isDark ? Colors.white : Colors.black;
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, bottom: 3),
      child: Align(alignment: Alignment.centerLeft, child: ConstrainedBox(constraints: BoxConstraints(maxWidth: bw),
        child: DecoratedBox(
          decoration: BoxDecoration(color: bg, borderRadius: const BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16), bottomLeft: Radius.circular(2), bottomRight: Radius.circular(16))),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: text.isEmpty
                ? const SizedBox.shrink()
                : md.MarkdownBody(
                    data: text,
                    selectable: false,
                    styleSheet: _mdStyleSheet(fg, isDark),
                    onTapLink: _launchUrl,
                  )),
        )),
      ),
    );
  }
}

// ====== TOOL STATUS / THINKING ======
class _ToolStatus extends StatelessWidget {
  final String text;
  const _ToolStatus({required this.text});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 2),
        child: Container(
          decoration: BoxDecoration(
              color: const Color(0xFF007AFF).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.all(8),
          child: Text(text,
              style: const TextStyle(
                  color: Color(0xFF007AFF),
                  fontSize: 12,
                  fontFamily: 'monospace')),
        ),
      );
}

class _ThinkingBlock extends StatefulWidget {
  final String text;
  final bool isDark;
  const _ThinkingBlock({required this.text, required this.isDark});
  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    final fg =
        widget.isDark ? const Color(0xFF9E9EA4) : const Color(0xFF8A8A8E);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 2),
      child: Container(
        decoration: BoxDecoration(
            color: fg.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8)),
        child: Column(children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                const Icon(Icons.psychology_outlined,
                    size: 14, color: Color(0xFF8A8A8E)),
                const SizedBox(width: 6),
                Expanded(
                    child: Text('思考过程',
                        style: TextStyle(
                            color: fg,
                            fontSize: 12,
                            fontWeight: FontWeight.w500))),
                AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Icons.expand_more, color: fg, size: 16)),
              ]),
            ),
          ),
          if (_open)
            Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Text(widget.text,
                    style: TextStyle(
                        color: fg,
                        fontSize: 11,
                        height: 1.3,
                        fontFamily: 'monospace'))),
        ]),
      ),
    );
  }
}

// ====== APP BAR ======
class _Bar extends StatelessWidget implements PreferredSizeWidget {
  final bool conn, isDark, streaming, autoPlay, reconnecting;
  final String? error;
  final String accountName;
  final VoidCallback onToggleAutoPlay;
  const _Bar({
    required this.conn, required this.isDark, this.error,
    required this.accountName,
    this.streaming = false, this.autoPlay = false, this.reconnecting = false,
    required this.onToggleAutoPlay,
  });
  @override Size get preferredSize => const Size.fromHeight(44);
  @override Widget build(BuildContext ctx) {
    final bg = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF7F7F8);
    final txt = isDark ? Colors.white : Colors.black;
    const accent = Color(0xFF5B4BD6);
    final statusText = conn
        ? '在线'
        : (reconnecting ? '重连中…' : (error ?? '未连接'));
    final statusColor = conn
        ? const Color(0xFF34C759)
        : (reconnecting ? const Color(0xFFFF9500) : const Color(0xFFFF6B6B));
    return AppBar(
      backgroundColor: bg, elevation: 0, titleSpacing: 0,
      // 显式菜单按钮:打开左侧账户抽屉(左边缘右滑亦可)。
      leading: Builder(builder: (c) => IconButton(
        icon: const Icon(Icons.menu_rounded, size: 22),
        onPressed: () => Scaffold.of(c).openDrawer(),
        tooltip: '账户',
      )),
      title: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(accountName,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: txt)),
          // 流式输出时左上角显示「三个点逐个高亮」的打字动画
          if (streaming)
            Row(mainAxisSize: MainAxisSize.min, children: [
              _TypingDots(color: accent),
              const SizedBox(width: 6),
              Text('正在输入...', style: TextStyle(fontSize: 11, color: accent)),
            ])
          else
            Text(statusText, style: TextStyle(fontSize: 11, color: statusColor)),
        ]),
      ),
      actions: [
        // 喇叭自动播放开关(默认关、持久化)。tint 色块保证浅/暗模式对比度。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggleAutoPlay,
            child: Tooltip(
              message: autoPlay ? '自动播放:开' : '自动播放:关',
              child: Container(
                width: 36, height: 36, alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: autoPlay
                      ? accent
                      : accent.withValues(alpha: isDark ? 0.22 : 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  autoPlay ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                  size: 20,
                  color: autoPlay ? Colors.white : accent,
                ),
              ),
            ),
          ),
        ),
        IconButton(icon: Icon(Icons.more_vert, size: 20, color: txt), onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => const SettingsScreen()))),
      ],
    );
  }
}

// 三个圆点逐个高亮,用于流式输出时的"正在输入"动画。
// 每个点相位错开 1/3,亮度/大小随正弦脉动,形成从左到右流动的脉动波。
class _TypingDots extends StatefulWidget {
  final Color color;
  const _TypingDots({required this.color});
  @override State<_TypingDots> createState() => _TypingDotsState();
}
class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  }
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final v = _c.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(3, (i) {
            // 每个点相位错开 1/3,脉动峰值在 phase=0.5
            final phase = (v + i / 3) % 1.0;
            final pulse = sin(phase * pi); // 0→1→0
            final opacity = 0.25 + 0.75 * pulse;
            final scale = 0.7 + 0.3 * pulse;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.4),
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 6, height: 6,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: opacity),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

// ====== INPUT BAR ======
class _InputBar extends StatelessWidget {
  final VoidCallback send, showAttachment;
  final TextEditingController ctrl; final FocusNode focus;
  final bool isDark, hasText;
  final VoidCallback onVoiceStart;
  final void Function(double dy) onVoiceMove;
  final VoidCallback onVoiceEnd;
  final List<SlashCommand> slashMatches;
  final ValueChanged<String> onPickSlash;

  const _InputBar({
    required this.send, required this.showAttachment,
    required this.ctrl, required this.focus,
    required this.isDark, required this.hasText,
    required this.onVoiceStart, required this.onVoiceMove, required this.onVoiceEnd,
    this.slashMatches = const [], required this.onPickSlash,
  });

  @override
  Widget build(BuildContext ctx) {
    final bg = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF7F7F8);
    final fieldBg = isDark ? const Color(0xFF3A3A3C) : const Color(0xFFFFFFFF);
    final txt = isDark ? Colors.white : Colors.black;
    final hint = isDark ? const Color(0xFF6D6D72) : const Color(0xFFC4C4C6);
    const accent = Color(0xFF5B4BD6);
    final pad = MediaQuery.of(ctx).padding;
    final keyVisible = MediaQuery.of(ctx).viewInsets.bottom > 0;

    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (slashMatches.isNotEmpty)
        _SlashSuggestion(matches: slashMatches, isDark: isDark, onPick: onPickSlash),
      Container(
      padding: EdgeInsets.only(left: 6, right: 6, top: 6, bottom: (keyVisible ? 6 : 6 + pad.bottom)),
      decoration: BoxDecoration(color: bg, border: Border(top: BorderSide(color: isDark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E5EA), width: 0.5))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        GestureDetector(onTap: showAttachment, child: SizedBox(width: 44, height: 44, child: Center(child: Icon(Icons.attach_file_rounded, color: accent, size: 24)))),
        Expanded(child: Container(
          constraints: const BoxConstraints(maxHeight: 120),
          decoration: BoxDecoration(color: fieldBg, borderRadius: BorderRadius.circular(22), border: Border.all(color: isDark ? const Color(0xFF545458) : const Color(0xFFE0E0E5), width: 1)),
          child: TextField(
            controller: ctrl, focusNode: focus, maxLines: null, textCapitalization: TextCapitalization.sentences,
            style: TextStyle(color: txt, fontSize: 16),
            decoration: InputDecoration(
              hintText: '消息', hintStyle: TextStyle(color: hint, fontSize: 16),
              border: InputBorder.none, isCollapsed: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
          ),
        )),
        const SizedBox(width: 6),
        hasText
          ? GestureDetector(
              onTap: send,
              child: Container(width: 42, height: 42,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF5B4BD6)),
                child: const Icon(Icons.send_rounded, color: Colors.white, size: 22)),
            )
          : GestureDetector(
              onLongPressStart: (_) => onVoiceStart(),
              onLongPressMoveUpdate: (d) => onVoiceMove(d.localPosition.dy),
              onLongPressEnd: (_) => onVoiceEnd(),
              child: Container(width: 42, height: 42,
                decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withValues(alpha: isDark ? 0.22 : 0.12)),
                child: Icon(Icons.mic_none_rounded, color: accent, size: 22)),
            ),
      ]),
      ),
    ],
    );
  }
}

/// 内置斜杠命令(名称 + 说明)。
class SlashCommand {
  final String cmd;
  final String desc;
  const SlashCommand(this.cmd, this.desc);
}

/// 输入 / 时浮在输入框上方的命令候选列表。点击某项把命令名填入输入框。
class _SlashSuggestion extends StatelessWidget {
  final List<SlashCommand> matches;
  final bool isDark;
  final ValueChanged<String> onPick;
  const _SlashSuggestion({required this.matches, required this.isDark, required this.onPick});

  @override
  Widget build(BuildContext ctx) {
    final bg = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFFFFFFF);
    final fg = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final sub = isDark ? const Color(0xFF9E9EA4) : const Color(0xFF8A8A8E);
    final accent = const Color(0xFF5B4BD6);
    final div = isDark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E5EA);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
        constraints: const BoxConstraints(maxHeight: 220),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: div, width: 0.5),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.08), blurRadius: 12, offset: const Offset(0, 2))],
        ),
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: matches.length,
          separatorBuilder: (_, __) => Divider(height: 1, thickness: 0.5, color: div, indent: 50),
          itemBuilder: (_, i) {
            final c = matches[i];
            return InkWell(
              onTap: () => onPick(c.cmd),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(children: [
                  Container(
                    width: 28, height: 28, alignment: Alignment.center,
                    decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                    child: Icon(Icons.terminal_rounded, size: 16, color: accent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(c.cmd, style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w600, fontFamily: 'monospace')),
                    const SizedBox(height: 1),
                    Text(c.desc, style: TextStyle(color: sub, fontSize: 12)),
                  ])),
                ]),
              ),
            );
          },
        ),
      ),
    );
  }
}
