import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:get/get.dart';
import '../../api/models/project.dart';
import '../../controllers/project_controller.dart';
import '../../controllers/session_controller.dart';
import '../../controllers/settings_controller.dart';
import '../../controllers/tablet_tool_controller.dart';
import '../../utils/layout_utils.dart';
import '../../init.dart';
import '../../models/model_info.dart';
import '../../models/session_runtime_state.dart';
import '../../routes.dart';
import '../../utils/app_theme.dart';
import '../../utils/snackbar_utils.dart';
import '../../utils/translations.dart';
import '../../utils/url_utils.dart';
import 'input_stack.dart';
import '../../controllers/voice_input_controller.dart';
import '../../widgets/voice_floating_overlay.dart';
import 'tablet/in_app_browser_view.dart';
import '../../controllers/vcs_controller.dart';
import 'vcs_branch_sheet.dart';
import '../../services/mention_search_service.dart';
import '../../utils/mention_parse.dart';
import '../../utils/mention_rank.dart';
import 'inline_chip_controller.dart';

class PromptInput extends StatefulWidget {
  final String sessionId;

  const PromptInput({super.key, required this.sessionId});

  @override
  State<PromptInput> createState() => _PromptInputState();
}

class _PromptInputState extends State<PromptInput> with WidgetsBindingObserver {
  late final InlineChipTextEditingController _textController;
  final FocusNode _focusNode = FocusNode();
  bool _hasText = false;
  bool _wasKeyboardOpen = false;

  // ── @ 路径提及菜单 ──
  final _layerLink = LayerLink();
  OverlayEntry? _suggestionOverlayEntry;
  List<MentionRankRow> _matched = [];
  String _currentQuery = '';
  int _triggerIndex = -1;
  int _triggerCursor = -1;
  int _selectedIndex = 0;
  Timer? _suggestDebounce;
  final _mentionService = MentionSearchService();
  final _suggestionScrollController = ScrollController();

  SessionController get _ctrl => Get.find<SessionController>();

  VoiceInputController get _voiceCtrl =>
      Get.isRegistered<VoiceInputController>()
      ? Get.find<VoiceInputController>()
      : Get.put(VoiceInputController());

  Worker? _voiceTargetWorker;

  @override
  void initState() {
    super.initState();
    _textController = InlineChipTextEditingController(
      onChipTap: (relativePath) {
        if (Get.isRegistered<TabletToolController>()) {
          Get.find<TabletToolController>().openFile(
            relativePath,
            basenameOf(relativePath),
          );
        }
      },
    );
    _focusNode.onKeyEvent = _onKeyEvent;
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        _hideOverlay();
      }
    });
    WidgetsBinding.instance.addObserver(this);
    _textController.addListener(() {
      // 值不变不 setState：IME 组合、光标移动等每次输入事件都会进 listener，
      // 无守卫时整块输入区（工具栈/附件/操作栏）被无谓重建。
      final hasText = _textController.text.trim().isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
      }
      _scheduleMentionScan();
    });
    // 本会话成为激活会话时，把语音输入目标指向本输入框，
    // 保证连续语音模式在切换 session 后输出到当前会话。
    _voiceTargetWorker = ever(_ctrl.activeSessionId, (id) {
      if (id == widget.sessionId) {
        _voiceCtrl.setTargetController(_textController);
        _voiceCtrl.autoSendHandler = _handleAutoSend;
      }
    });
    if (_ctrl.activeSessionId.value == widget.sessionId) {
      _voiceCtrl.setTargetController(_textController);
      _voiceCtrl.autoSendHandler = _handleAutoSend;
    }
  }

  @override
  void didUpdateWidget(PromptInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _hideOverlay();
    }
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _hideOverlay();
    _mentionService.dispose();
    _suggestionScrollController.dispose();
    if (_voiceCtrl.autoSendHandler == _handleAutoSend) {
      _voiceCtrl.autoSendHandler = null;
    }
    // 本输入框销毁（会话关闭/PageView 回收远页）时解除语音目标绑定；
    // 若单点录音仍在向本输入框写入，一并停止，避免结果无人消费、麦克风空转。
    unawaited(_voiceCtrl.detachTarget(_textController));
    _voiceTargetWorker?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final bottom = View.of(context).viewInsets.bottom;
    if (bottom > 100) {
      _wasKeyboardOpen = true;
    } else if (bottom == 0 && _wasKeyboardOpen) {
      _wasKeyboardOpen = false;
      if (_focusNode.hasFocus) {
        _focusNode.unfocus();
      }
    }
  }

  void _handleSend() {
    _submitMessage(_textController.text);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // @ 菜单打开时优先处理导航与选择（桌面端与外接键盘均生效）
    if (_suggestionOverlayEntry != null && _matched.isNotEmpty) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _moveSelection(1);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _moveSelection(-1);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter ||
          event.logicalKey == LogicalKeyboardKey.tab) {
        final composing = _textController.value.composing;
        if (composing.isValid && !composing.isCollapsed) {
          return KeyEventResult.ignored;
        }
        _selectSuggestion(_selectedIndex);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _hideOverlay();
        return KeyEventResult.handled;
      }
    }

    // 桌面端快捷键（Enter 发送 / Ctrl+V 贴图 / Esc 闭环）仅桌面生效：
    // 移动端保留系统原生行为，外接物理键盘也不拦截。
    if (!isDesktop) return KeyEventResult.ignored;

    // 1. Ctrl+V (Windows/Linux) 或 Cmd+V (macOS)：优先尝试粘贴剪贴板二进制图片
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      _handlePaste();
      return KeyEventResult.handled;
    }

    // 2. Enter 键发送（支持主键盘 Enter 与小键盘 NumPad Enter，排除 Shift+Enter 换行）
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (isEnter && !HardwareKeyboard.instance.isShiftPressed) {
      // IME 输入法合成态防护：打拼音时无论是空格还是 Enter 上屏，绝不触发误发送
      final composing = _textController.value.composing;
      if (composing.isValid && !composing.isCollapsed) {
        return KeyEventResult.ignored;
      }

      final state = _ctrl.stateOf(widget.sessionId);
      final hasPendingPermission =
          _ctrl.sessionIdWithPendingPermission(widget.sessionId) != null;
      final inputEnabled =
          widget.sessionId.isNotEmpty && !hasPendingPermission;
      final canSend =
          _hasText ||
          state.attachedFiles.isNotEmpty ||
          state.attachedImages.isNotEmpty;

      if (inputEnabled && canSend) {
        _handleSend();
        return KeyEventResult.handled;
      }
      // 若空消息或不可发送，吞掉 Enter 避免插入无谓换行
      return KeyEventResult.handled;
    }

    // 3. Esc 键闭环：优先关闭自定义 Overlay 弹窗/路由弹窗，其次中止生成；空闲时失焦。
    // 有 Dialog / BottomSheet / PopupMenuRoute 盖在上面时不处理，把 Esc 让给上层关闭。
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_suggestionOverlayEntry != null) {
        _hideOverlay();
        return KeyEventResult.handled;
      }
      final dismissPopup = _activePromptPopupDismiss;
      if (dismissPopup != null) {
        dismissPopup();
        return KeyEventResult.handled;
      }
      // showMenu 等 Material 路由弹窗不在 Get 统计内：顶层路由不是本页时让给它。
      if (ModalRoute.of(context)?.isCurrent == false) {
        return KeyEventResult.ignored;
      }
      if (Get.isDialogOpen == true || Get.isBottomSheetOpen == true) {
        return KeyEventResult.ignored;
      }
      final state = _ctrl.stateOf(widget.sessionId);
      if (state.isGenerating.value) {
        _handleAbort();
        return KeyEventResult.handled;
      } else if (_focusNode.hasFocus) {
        _focusNode.unfocus();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Future<void> _handlePaste() async {
    try {
      final image = await _readClipboardImage();
      if (image != null && image.bytes.isNotEmpty) {
        final state = _ctrl.stateOf(widget.sessionId);
        if (state.attachedImages.length >= 5) {
          Snack.warning('最多只能上传 5 张图片');
          return;
        }
        state.attachedImages.add(image);
        return;
      }
    } catch (_) {
      // 读取剪贴板图像异常时静默降级为文本粘贴
    }

    // 剪贴板无图片时，回退到系统文本粘贴；IME 合成中则跳过，
    // 避免手动改值破坏拼音上屏。
    final composing = _textController.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _insertTextAtCursor(text);
    }
  }

  Future<PickedImage?> _readClipboardImage() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;

    final reader = await clipboard.read();
    final format = reader.canProvide(Formats.png)
        ? Formats.png
        : (reader.canProvide(Formats.jpeg) ? Formats.jpeg : null);
    if (format == null) return null;

    final completer = Completer<Uint8List?>();
    final progress = reader.getFile(
      format,
      (file) async {
        if (!completer.isCompleted) {
          completer.complete(await file.readAll());
        }
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    if (progress == null) return null;
    final bytes = await completer.future;
    if (bytes == null || bytes.isEmpty) return null;

    final isPng = format == Formats.png;
    return (
      bytes: bytes,
      mime: isPng ? 'image/png' : 'image/jpeg',
      ext: isPng ? 'png' : 'jpg',
    );
  }

  void _insertTextAtCursor(String text) {
    final selection = _textController.selection;
    final currentText = _textController.text;
    final start = selection.start < 0 ? currentText.length : selection.start;
    final end = selection.end < 0 ? currentText.length : selection.end;
    final before = currentText.substring(0, start);
    final after = currentText.substring(end);
    final newText = '$before$text$after';
    final newOffset = start + text.length;
    _textController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    );
  }

  /// 统一发送入口：文本 + 已附图片/文件一并发送，发送后清空附件。
  /// [clearInput] 为 false 时（长按语音直发）不清空输入框。
  Future<void> _submitMessage(String text, {bool clearInput = true}) async {
    final t = text.trim();
    final state = _ctrl.stateOf(widget.sessionId);
    // 从文本中提取通过 @ 提及的文件或目录（边界/尾标点/去重见 mention_parse，
    // 对齐后端 build-request-parts.ts 与 FILE_REGEX 语义）。
    for (final ref in parseMentions(text)) {
      final mentionPath = ref.lineRange.isNotEmpty
          ? '${ref.path} #${ref.lineRange}'
          : ref.path;
      if (!state.attachedFiles.contains(mentionPath)) {
        state.attachedFiles.add(mentionPath);
      }
    }
    final files = state.attachedFiles.toList();
    final images = state.attachedImages.toList();
    if (t.isEmpty && files.isEmpty && images.isEmpty) return;
    _hideOverlay();
    _focusNode.unfocus();
    // 先按原时序清空输入与附件（乐观上屏），再等待发送结果；
    // 失败时在下方回填，不在 POST 窗口保留输入以免重复提交。
    if (clearInput) {
      _textController.clear();
      _hasText = false;
    }
    state.attachedFiles.clear();
    state.attachedImages.clear();
    _voiceCtrl.onTextSubmitted(_textController);
    final ok = await _ctrl.sendPrompt(
      t,
      images: images,
      overrideFiles: files.isNotEmpty ? files : null,
      targetSessionId: widget.sessionId,
    );
    if (ok) return;
    // 发送失败（排队/重试等成功路径除外）：把内容还给输入框与附件栏，
    // 避免静默丢失；用户可修改后重发。仅在各自为空时回填，不覆盖新输入。
    // POST 窗口内页签可能已关闭（组件卸载）：输入框已 dispose 不可写，
    // 附件仍属会话运行时状态，可安全回填。
    if (mounted && _textController.text.trim().isEmpty) {
      _textController.text = t;
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: _textController.text.length),
      );
    }
    if (state.attachedImages.isEmpty && images.isNotEmpty) {
      state.attachedImages.addAll(images);
    }
    if (state.attachedFiles.isEmpty && files.isNotEmpty) {
      state.attachedFiles.addAll(files);
    }
  }

  /// 语音自动发送：识别到“发送指令”后由 VoiceInputController 回调调用，
  /// 连同已附图片/文件一起发送。
  void _handleAutoSend(String text) {
    _submitMessage(text);
  }

  Future<void> _handleAbort() async {
    if (widget.sessionId != _ctrl.activeSessionId.value) {
      _ctrl.selectSession(widget.sessionId);
    }
    await _ctrl.abortGeneration();
  }

  static const _imageMimeByExt = <String, String>{
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'gif': 'image/gif',
    'bmp': 'image/bmp',
  };

  /// Backend (image.normalize via Photon) cannot decode HEIC/HEIF and the
  /// failure aborts the whole message send, so reject them at pick time.
  static const _unsupportedImageExts = {'heic', 'heif'};

  Future<void> _pickImages() async {
    final picker = ImagePicker();
    final result = await picker.pickMultiImage(limit: 5);
    if (result.isEmpty) return;
    final state = _ctrl.stateOf(widget.sessionId);
    for (final xfile in result) {
      final bytes = await xfile.readAsBytes();
      if (bytes.isEmpty) continue;
      final ext = _extFromPath(xfile.path);
      // HEIC 专用判断须在 mime 查表之前（表内无 heic，否则永远走通用提示）。
      if (_unsupportedImageExts.contains(ext)) {
        Snack.warning(LocaleKeys.mobileImageHeicUnsupported.tr);
        continue;
      }
      final mime = _imageMimeByExt[ext];
      if (mime == null) {
        Snack.warning(
          LocaleKeys.mobileImageUnsupportedFormat.trParams({'ext': ext}),
        );
        continue;
      }
      state.attachedImages.add((bytes: bytes, mime: mime, ext: ext));
    }
  }

  /// 从文件路径提取小写扩展名（image_picker 的 XFile 无 extension 字段）。
  static String _extFromPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '';
    return path.substring(dot + 1).toLowerCase();
  }

  /// 当前模型不支持识图（或模型未知）且已附图片时，才显示「转文字」按钮。
  bool _canDescribeImages(SessionRuntimeState state) {
    final model = _ctrl.resolveModel(state.selectedModel.value);
    if (model != null && model.supportsImage) return false;
    return _ctrl.hasVisionModel;
  }

  /// 手动「转文字」：把已附图片发给识图模型，拿到的文本替换图片附件并填入
  /// 输入框，用户确认后再发送。出错时保留图片并提示，可重试。
  Future<void> _describeImages() async {
    final state = _ctrl.stateOf(widget.sessionId);
    if (state.isDescribingImages.value) return;
    final images = state.attachedImages.toList();
    if (images.isEmpty) return;

    if (!_ctrl.hasVisionModel) {
      Snack.warning(LocaleKeys.mobileNoVisionModelsHint.tr);
      return;
    }

    state.isDescribingImages.value = true;
    try {
      final result = await _ctrl.describeImagesToText(
        images,
        prompt: LocaleKeys.mobileImageDescribePrompt.tr,
      );
      if (result == null || result.trim().isEmpty) {
        Snack.error(LocaleKeys.mobileImageDescribeFailed.tr);
        return;
      }
      final cleaned = result.trim();
      // 仅移除本次送去识图的图片；描述期间新选的图片保留。
      state.attachedImages.removeWhere((img) => images.contains(img));
      final current = _textController.text;
      if (current.trim().isEmpty) {
        _textController.text = cleaned;
      } else {
        _textController.text = '$current\n\n$cleaned';
      }
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: _textController.text.length),
      );
      _hasText = true;
    } finally {
      state.isDescribingImages.value = false;
    }
  }

  // ── @ 路径提及菜单 ──

  void _scheduleMentionScan() {
    _suggestDebounce?.cancel();
    _suggestDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _scanMention();
    });
  }

  void _scanMention() async {
    final text = _textController.text;
    final selection = _textController.selection;
    if (!selection.isCollapsed || selection.start < 0) {
      _hideOverlay();
      return;
    }
    final cursor = selection.start;
    var at = -1;
    for (var i = cursor - 1; i >= 0; i--) {
      final char = text[i];
      if (char == '\n') break;
      if (char == '@') {
        if (i == 0 || isMentionBoundary(text[i - 1])) {
          at = i;
          break;
        }
      }
    }
    if (at == -1) {
      _hideOverlay();
      return;
    }
    final query = text.substring(at + 1, cursor);
    if (RegExp(r'\s').hasMatch(query)) {
      _hideOverlay();
      return;
    }
    // 裸 @（无查询内容）不发请求、不弹菜单：空 query 后端只能返回任意前 N 个，
    // 与用户意图无关；打出首字后再请求。
    if (query.trim().isEmpty) {
      _hideOverlay();
      return;
    }
    _triggerIndex = at;
    _triggerCursor = cursor;
    _currentQuery = query;
    final results = await _mentionService.search(query);
    if (!mounted || _currentQuery != query) return;
    _matched = results;
    _selectedIndex = 0;
    if (_matched.isEmpty) {
      _hideOverlay();
      return;
    }
    if (_suggestionOverlayEntry == null) {
      final overlay = Overlay.maybeOf(context);
      if (overlay == null) return;
      _suggestionOverlayEntry = OverlayEntry(
        builder: (_) => _buildSuggestionOverlay(),
      );
      overlay.insert(_suggestionOverlayEntry!);
    } else {
      _suggestionOverlayEntry?.markNeedsBuild();
    }
  }

  void _moveSelection(int delta) {
    if (_matched.isEmpty) return;
    setState(() {
      _selectedIndex = (_selectedIndex + delta + _matched.length) % _matched.length;
    });
    _suggestionOverlayEntry?.markNeedsBuild();
    if (_suggestionScrollController.hasClients) {
      const itemHeight = 44.0;
      final targetOffset = (_selectedIndex * itemHeight).clamp(
        0.0,
        _suggestionScrollController.position.maxScrollExtent,
      );
      _suggestionScrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
      );
    }
  }

  void _selectSuggestion(int index) {
    if (index < 0 || index >= _matched.length) return;
    final path = _matched[index].path;
    final text = _textController.text;
    // 用触发时的 cursor：async 等待期间光标若已移动则放弃，避免切错文本。
    if (_triggerIndex < 0 ||
        _triggerCursor < 0 ||
        _triggerCursor > text.length ||
        _triggerIndex > _triggerCursor) {
      _hideOverlay();
      return;
    }
    final before = text.substring(0, _triggerIndex);
    final after = text.substring(_triggerCursor);
    final insertion = '@$path ';
    final newOffset = _triggerIndex + insertion.length;
    _textController.value = TextEditingValue(
      text: '$before$insertion$after',
      selection: TextSelection.collapsed(offset: newOffset),
    );
    // chip 范围不含尾空格：删空格不带走整颗胶囊。
    _textController.registerChip(_triggerIndex, _triggerIndex + '@$path'.length);
    _hideOverlay();
  }

  void _hideOverlay() {
    if (_suggestionOverlayEntry != null) {
      if (_suggestionOverlayEntry!.mounted) {
        _suggestionOverlayEntry!.remove();
      }
      _suggestionOverlayEntry = null;
    }
    _matched.clear();
    _currentQuery = '';
    _triggerIndex = -1;
    _triggerCursor = -1;
  }

  Widget _buildSuggestionOverlay() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final total = _matched.length;
    final screenWidth = MediaQuery.of(context).size.width;
    final overlayWidth = (screenWidth - 32).clamp(260.0, 480.0);

    return Positioned(
      width: overlayWidth,
      child: CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: const Offset(0, -8),
        child: Material(
          elevation: 8,
          color: isDark ? const Color(0xFF1E1F29) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isDark ? const Color(0xFF2D2F3F) : const Color(0xFFE2E8F0),
              width: 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView.builder(
              controller: _suggestionScrollController,
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: total,
              itemBuilder: (context, index) {
                final isSelected = index == _selectedIndex;
                final match = _matched[index];
                final rawBase = basenameOf(match.path);
                final name = match.isDir ? '$rawBase/' : rawBase;
                return _buildSuggestionItem(
                  icon: match.isDir
                      ? CupertinoIcons.folder
                      : CupertinoIcons.doc_text,
                  title: name,
                  subtitle: match.path,
                  isSelected: isSelected,
                  onTap: () => _selectSuggestion(index),
                  indices: match.baseIndices,
                  isDark: isDark,
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSuggestionItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isSelected,
    required VoidCallback onTap,
    required List<int> indices,
    required bool isDark,
  }) {
    final spans = <TextSpan>[];
    if (indices.isEmpty) {
      spans.add(TextSpan(text: title));
    } else {
      final indexSet = indices.toSet();
      for (var i = 0; i < title.length; i++) {
        final char = title[i];
        final isMatched = indexSet.contains(i);
        spans.add(
          TextSpan(
            text: char,
            style: TextStyle(
              fontWeight: isMatched ? FontWeight.bold : FontWeight.normal,
              color: isMatched
                  ? const Color(0xFF3B82F6)
                  : (isDark ? Colors.white70 : Colors.black87),
            ),
          ),
        );
      }
    }

    return InkWell(
      onTap: onTap,
      child: Container(
        color: isSelected
            ? (isDark ? const Color(0xFF2D2F3F) : const Color(0xFFF1F5F9))
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: isDark ? Colors.white60 : Colors.black54,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RichText(
                    text: TextSpan(
                      children: spans,
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : Colors.black45,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Obx(() {
      final state = _ctrl.stateOf(widget.sessionId);
      final isWorking = state.isGenerating.value;
      final selectedModelName = _ctrl.selectedModelName(
        state.selectedModel.value,
      );
      final agent = state.selectedAgent.value;
      final models = _ctrl.availableModels;
      final levels = state.thinkingLevels.toList();
      final selectedLevel = state.selectedThinkingLevel.value;
      final hasSession = widget.sessionId.isNotEmpty;

      final hasPendingPermission =
          _ctrl.sessionIdWithPendingPermission(widget.sessionId) != null;
      final inputEnabled = hasSession && !hasPendingPermission;

      final isDark = theme.brightness == Brightness.dark;
      final bg = context.appColors.inputBg;

      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SessionStatusStack(sessionId: widget.sessionId),
            PendingPromptBar(sessionId: widget.sessionId),
            StartExecutionButton(sessionId: widget.sessionId),
            Obx(() {
              final files = state.attachedFiles;
              final images = state.attachedImages;
              if (files.isEmpty && images.isEmpty) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: _AttachmentsBar(
                  files: files.toList(),
                  images: images.toList(),
                  onRemoveFile: (f) => files.remove(f),
                  onRemoveImage: (i) => images.removeAt(i),
                  onDescribeImages:
                      images.isNotEmpty && _canDescribeImages(state)
                      ? _describeImages
                      : null,
                  describing: state.isDescribingImages.value,
                  visionModelName: _ctrl.visionModelName,
                ),
              );
            }),
            Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.bottomCenter,
              children: [
                _UtilityBar(
                  textController: _textController,
                  onSendPhrase: (text, {overrideAgent, overrideModel}) {
                    _focusNode.unfocus();
                    _ctrl.sendPrompt(
                      text,
                      targetSessionId: widget.sessionId,
                      overrideAgent: overrideAgent,
                      overrideModel: overrideModel,
                    );
                    _voiceCtrl.onTextSubmitted(_textController);
                  },
                  onSendVoice: (text) {
                    _submitMessage(text, clearInput: false);
                  },
                ),
                Positioned(
                  bottom: 70,
                  child: VoiceFloatingOverlay(
                    controller: Get.isRegistered<VoiceInputController>()
                        ? Get.find<VoiceInputController>()
                        : Get.put(VoiceInputController()),
                  ),
                ),
              ],
            ),
            CompositedTransformTarget(
              link: _layerLink,
              child: Container(
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(
                      alpha: isDark ? 0.2 : 0.12,
                    ),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.04),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: _textController,
                      focusNode: _focusNode,
                      minLines: isDesktop ? 2 : 1,
                      maxLines: isDesktop ? 8 : 4,
                      enabled: inputEnabled,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: !hasSession
                            ? 'Select a session'
                            : hasPendingPermission
                            ? LocaleKeys.chatConfirmPermissionsFirst.tr
                            : isWorking
                            ? 'Generating...'
                            : 'Type a message...',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        filled: false,
                        contentPadding: EdgeInsets.fromLTRB(
                          10,
                          isDesktop ? 10 : 8,
                          10,
                          isDesktop ? 10 : 8,
                        ),
                        isDense: true,
                      ),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 14,
                        height: isDesktop ? 1.5 : null,
                      ),
                    ),
                    _ActionBar(
                      hasSession: hasSession,
                      isGenerating: isWorking,
                      hasPendingPermission: hasPendingPermission,
                      canSend:
                          _hasText ||
                          state.attachedFiles.isNotEmpty ||
                          state.attachedImages.isNotEmpty,
                      model: state.selectedModel.value,
                      models: models,
                      thinkingLevel: selectedLevel,
                      thinkingLevels: levels,
                      agent: agent,
                      agents: _ctrl.availableAgents,
                      selectedModelName: selectedModelName,
                      onSend: _handleSend,
                      onAbort: _handleAbort,
                      onPickImage: _pickImages,
                      onSelectModel: (m) {
                        if (widget.sessionId != _ctrl.activeSessionId.value) {
                          _ctrl.selectSession(widget.sessionId);
                        }
                        _ctrl.selectModel(m);
                      },
                      onSelectThinkingLevel: (l) {
                        if (widget.sessionId != _ctrl.activeSessionId.value) {
                          _ctrl.selectSession(widget.sessionId);
                        }
                        _ctrl.selectThinkingLevel(l);
                      },
                      onSelectAgent: (a) {
                        if (widget.sessionId != _ctrl.activeSessionId.value) {
                          _ctrl.selectSession(widget.sessionId);
                        }
                        _ctrl.selectAgent(a);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}

// ── Action Bar ──

class _ActionBar extends StatelessWidget {
  final bool hasSession;
  final bool isGenerating;
  final bool hasPendingPermission;
  final bool canSend;
  final String model;
  final List<ModelInfo> models;
  final String thinkingLevel;
  final List<String> thinkingLevels;
  final String agent;
  final List<String> agents;
  final String selectedModelName;
  final VoidCallback onSend;
  final VoidCallback onAbort;
  final VoidCallback onPickImage;
  final ValueChanged<String> onSelectModel;
  final ValueChanged<String> onSelectThinkingLevel;
  final ValueChanged<String> onSelectAgent;

  const _ActionBar({
    required this.hasSession,
    required this.isGenerating,
    required this.hasPendingPermission,
    required this.canSend,
    required this.model,
    required this.models,
    required this.thinkingLevel,
    required this.thinkingLevels,
    required this.agent,
    required this.agents,
    required this.selectedModelName,
    required this.onSend,
    required this.onAbort,
    required this.onPickImage,
    required this.onSelectModel,
    required this.onSelectThinkingLevel,
    required this.onSelectAgent,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 36,
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _BarIconBtn(
            icon: CupertinoIcons.photo,
            tooltip: LocaleKeys.mobileAttachImage.tr,
            enabled: hasSession && !isGenerating,
            onTap: onPickImage,
            theme: theme,
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (models.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    _ModelSelector(
                      models: models,
                      selectedId: model,
                      selectedName: selectedModelName,
                      onSelect: onSelectModel,
                      theme: theme,
                    ),
                  ],
                  if (thinkingLevels.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    _ThinkingLevelSelector(
                      levels: thinkingLevels,
                      selected: thinkingLevel,
                      onSelect: onSelectThinkingLevel,
                      theme: theme,
                    ),
                  ],
                  if (agents.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    _AgentSelector(
                      agents: agents,
                      selected: agent,
                      onSelect: onSelectAgent,
                      theme: theme,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          _SendStopButton(
            isGenerating: isGenerating,
            canSend: canSend,
            enabled: hasSession && !hasPendingPermission,
            onSend: onSend,
            onAbort: onAbort,
          ),
        ],
      ),
    );
  }
}

// ── Send / Stop Action Button ──

class _SendStopButton extends StatelessWidget {
  final bool isGenerating;
  final bool canSend;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onAbort;

  const _SendStopButton({
    required this.isGenerating,
    required this.canSend,
    required this.enabled,
    required this.onSend,
    required this.onAbort,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isStopping = isGenerating && !canSend;
    final isSendActive = enabled && canSend;

    Color bgColor;
    Color iconColor;
    IconData iconData;
    String tooltip;
    VoidCallback? onTap;

    if (isStopping) {
      bgColor = theme.colorScheme.error;
      iconColor = theme.colorScheme.onError;
      iconData = Icons.stop_rounded;
      tooltip = LocaleKeys.mobileStopEsc.tr;
      onTap = onAbort;
    } else {
      bgColor = isSendActive
          ? theme.colorScheme.primary
          : theme.colorScheme.onSurface.withValues(alpha: 0.08);
      iconColor = isSendActive
          ? theme.colorScheme.onPrimary
          : theme.colorScheme.onSurface.withValues(alpha: 0.3);
      iconData = Icons.arrow_upward_rounded;
      tooltip = LocaleKeys.mobileSendEnter.tr;
      onTap = isSendActive ? onSend : null;
    }

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Icon(
                iconData,
                key: ValueKey(iconData),
                size: 17,
                color: iconColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Utility bar: keyword / new session / phrases / terminal ──

class _UtilityBar extends StatelessWidget {
  final TextEditingController textController;
  final void Function(
    String text, {
    String? overrideAgent,
    String? overrideModel,
  })
  onSendPhrase;
  final ValueChanged<String> onSendVoice;

  const _UtilityBar({
    required this.textController,
    required this.onSendPhrase,
    required this.onSendVoice,
  });

  bool _isTabletMode(BuildContext context) => isTabletLayout(context);

  Future<void> _showQuickPhrases(BuildContext context) async {
    final settings = Get.find<SettingsController>();
    if (settings.commands.isEmpty && !settings.isLoadingCommands.value) {
      settings.fetchCommands();
    }
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return Obx(() {
          final cmdItems = settings.commandPhrases;
          final userItems = Global.quickPhrasesRx.toList();
          final all = [...cmdItems, ...userItems];

          if (all.isEmpty) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(LocaleKeys.mobileNoQuickPhrasesHint.tr),
              ),
            );
          }
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: MediaQuery.of(ctx).size.height * 0.3,
                maxHeight: MediaQuery.of(ctx).size.height * 0.5,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: all.map((p) {
                      final theme = Theme.of(ctx);
                      return ActionChip(
                        avatar: Icon(
                          p.isSystem ? Icons.terminal : Icons.bookmark_outline,
                          size: 14,
                          color: p.isSystem
                              ? theme.colorScheme.primary
                              : theme.colorScheme.secondary,
                        ),
                        label: Text(
                          p.name.isNotEmpty ? p.name : p.template,
                          style: TextStyle(
                            fontSize: 12,
                            color: p.isSystem
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          onSendPhrase(
                            p.template,
                            overrideAgent: p.agent.isNotEmpty ? p.agent : null,
                            overrideModel: p.model.isNotEmpty ? p.model : null,
                          );
                        },
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
          );
        });
      },
    );
  }

  void _showVcsBranchSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const VcsBranchSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessionCtrl = Get.find<SessionController>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  // 1. 手动压缩
                  IconButton(
                    tooltip: LocaleKeys.chatManualCompact.tr,
                    icon: const Icon(Icons.compress_outlined, size: 20),
                    onPressed: () => sessionCtrl.compactActiveSession(),
                  ),
                  // 2. 快捷短语
                  IconButton(
                    tooltip: LocaleKeys.csQuickPhrases.tr,
                    icon: const Icon(Icons.quickreply_outlined, size: 20),
                    onPressed: () => _showQuickPhrases(context),
                  ),
                  // 3. 终端
                  IconButton(
                    tooltip: LocaleKeys.mobileRemoteTerminal.tr,
                    icon: const Icon(Icons.terminal, size: 20),
                    onPressed: () {
                      if (_isTabletMode(context)) {
                        Get.find<TabletToolController>().focusTerminal();
                      } else {
                        Get.toNamed(AppRoutes.terminal);
                      }
                    },
                  ),
                  // 4. 预览
                  IconButton(
                    tooltip: LocaleKeys.tabletWebTab.tr,
                    icon: const Icon(CupertinoIcons.eye, size: 20),
                    onPressed: () => _openPreview(context),
                    onLongPress: () => _showBindPortDialog(context),
                  ),
                  // 5. 语音输入
                  _VoiceInputButton(
                    textController: textController,
                    onSendVoice: onSendVoice,
                  ),
                  // 6. Git 分支与状态
                  Obx(() {
                    final vcsCtrl = Get.find<VcsController>();
                    final hasChanges = vcsCtrl.hasUncommittedChanges;
                    final branchName = vcsCtrl.branch.value;
                    final tooltip = branchName.isNotEmpty
                        ? '${LocaleKeys.vcsBranch.tr}: $branchName'
                        : LocaleKeys.vcsBranch.tr;

                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          tooltip: tooltip,
                          icon: const Icon(
                            CupertinoIcons.arrow_branch,
                            size: 20,
                          ),
                          onPressed: () => _showVcsBranchSheet(context),
                        ),
                        if (hasChanges)
                          Positioned(
                            right: 8,
                            top: 8,
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    );
                  }),
                  // 7. 关键词检测指示器
                  Obx(() {
                    final sessionId = sessionCtrl.activeSessionId.value;
                    final showAlert = sessionId.isNotEmpty
                        ? sessionCtrl
                              .stateOf(sessionId)
                              .keywordDetectionAlert
                              .value
                        : false;
                    return SizedBox(
                      width: 24,
                      height: 24,
                      child: Center(
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: showAlert
                                ? Colors.redAccent
                                : Colors.transparent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          // 6. 新建session（靠右对齐）
          IconButton(
            tooltip: LocaleKeys.cmdNewSession.tr,
            icon: const Icon(CupertinoIcons.square_pencil, size: 20),
            onPressed: () => sessionCtrl.createNewSession(),
          ),
        ],
      ),
    );
  }

  /// Opens the preview: if the current project has a bound port, opens
  /// `server-host:port` directly; otherwise falls back to the default behavior
  /// (tablet: switch to the Web tab, phone: show the browser sheet).
  void _openPreview(BuildContext context) {
    final project = Get.find<ProjectController>().activeProject.value;
    final port = project != null
        ? Global.previewPortForProject(project.id)
        : null;
    if (port != null && port.isNotEmpty) {
      final url = buildPreviewUrl(Global.serverUrl, port);
      if (url != null) {
        // 若该预览 URL 已在浏览器中打开，则刷新该页，而不是新建标签。
        openUrlInApp(context, url, reloadIfOpen: true);
        return;
      }
    }
    if (_isTabletMode(context)) {
      Get.find<TabletToolController>().openUrl('');
    } else {
      Get.find<TabletToolController>().openBrowserSheet();
    }
  }

  /// Long-press entry: bind/clear the preview port for the current project.
  void _showBindPortDialog(BuildContext context) {
    final project = Get.find<ProjectController>().activeProject.value;
    if (project == null) return;

    showDialog<void>(
      context: context,
      builder: (_) => _BindPortDialog(project: project),
    );
  }
}

/// Dialog for binding/clearing the preview port of a project.
class _BindPortDialog extends StatefulWidget {
  final ProjectModel project;

  const _BindPortDialog({required this.project});

  @override
  State<_BindPortDialog> createState() => _BindPortDialogState();
}

class _BindPortDialogState extends State<_BindPortDialog> {
  late final TextEditingController _controller;
  late final ValueNotifier<String> _urlPreview;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: Global.previewPortForProject(widget.project.id) ?? '',
    );
    _urlPreview = ValueNotifier<String>(
      buildPreviewUrl(Global.serverUrl, _controller.text) ?? '',
    );
    _controller.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _controller.dispose();
    _urlPreview.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    _urlPreview.value =
        buildPreviewUrl(Global.serverUrl, _controller.text) ?? '';
  }

  Future<void> _confirm() async {
    final input = _controller.text.trim();
    if (input.isNotEmpty) {
      final port = int.tryParse(input);
      if (port == null || port < 1 || port > 65535) {
        Snack.warning(LocaleKeys.previewPortInvalid.tr);
        return;
      }
    }
    await Global.setPreviewPort(
      widget.project.id,
      input.isEmpty ? null : input,
    );
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(
        '${LocaleKeys.previewBindTitle.tr}\n${widget.project.displayName}',
        textAlign: TextAlign.center,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: LocaleKeys.previewPortHint.tr,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _confirm(),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<String>(
            valueListenable: _urlPreview,
            builder: (_, url, child) {
              return Text(
                url.isNotEmpty
                    ? '${LocaleKeys.previewBindPreview.tr}  ${maskUrl(url)}'
                    : '',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(LocaleKeys.cancel.tr),
        ),
        TextButton(
          onPressed: () async {
            await Global.setPreviewPort(widget.project.id, null);
            if (context.mounted) {
              Navigator.pop(context);
            }
          },
          child: Text(LocaleKeys.previewPortClear.tr),
        ),
        FilledButton(onPressed: _confirm, child: Text(LocaleKeys.ok.tr)),
      ],
    );
  }
}

// ── Bar Icon Button ──

class _BarIconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;
  final ThemeData theme;

  const _BarIconBtn({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
          child: Icon(
            icon,
            size: 16,
            color: enabled
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.onSurface.withValues(alpha: 0.3),
          ),
        ),
      ),
    );
  }
}

// ── Model Selector ──

class _ModelSelector extends StatelessWidget {
  final List<ModelInfo> models;
  final String selectedId;
  final String selectedName;
  final ValueChanged<String> onSelect;
  final ThemeData theme;

  const _ModelSelector({
    required this.models,
    required this.selectedId,
    required this.selectedName,
    required this.onSelect,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return _SelectorChip(
      label: selectedName,
      theme: theme,
      maxWidth: 160,
      onTap: () => _showMenu(context),
    );
  }

  void _showMenu(BuildContext context) async {
    final renderBox = context.findRenderObject() as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero);
    final width = (renderBox.size.width + 80).clamp(180.0, 280.0);

    final result = await _showPopup<String>(
      context: context,
      left: offset.dx - 10,
      top: offset.dy - (models.length * 28.0).clamp(0, 240) - 2,
      width: width,
      items: models.map((m) {
        final isSelected = m.key == selectedId || m.id == selectedId;
        return _PopupItem<String>(
          value: m.key,
          label: m.name.isNotEmpty ? m.name : m.id,
          selected: isSelected,
          height: 28,
          fontSize: 12,
          textAlign: TextAlign.left,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        );
      }).toList(),
    );
    if (result != null) onSelect(result);
  }
}

// ── Thinking Level Selector ──

class _ThinkingLevelSelector extends StatelessWidget {
  final List<String> levels;
  final String selected;
  final ValueChanged<String> onSelect;
  final ThemeData theme;

  const _ThinkingLevelSelector({
    required this.levels,
    required this.selected,
    required this.onSelect,
    required this.theme,
  });

  String _labelFor(String value) {
    if (value.isEmpty) return 'Default';
    return value[0].toUpperCase() + value.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    return _SelectorChip(
      label: _labelFor(selected),
      theme: theme,
      maxWidth: 88,
      onTap: () => _showMenu(context),
    );
  }

  void _showMenu(BuildContext context) async {
    final renderBox = context.findRenderObject() as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero);
    final width = (renderBox.size.width + 40).clamp(100.0, 160.0);
    final items = <String>['', ...levels];
    final menuHeight = items.length * 28.0;

    final result = await _showPopup<String>(
      context: context,
      left: offset.dx - 20,
      top: offset.dy - menuHeight - 2,
      width: width,
      items: items.map((lvl) {
        final isOff = lvl.isEmpty;
        return _PopupItem<String>(
          value: lvl,
          label: isOff ? 'Default' : _labelFor(lvl),
          selected: lvl == selected,
          height: 28,
          fontSize: 11,
        );
      }).toList(),
    );
    if (result != null) onSelect(result);
  }
}

// ── Agent Selector ──

class _AgentSelector extends StatelessWidget {
  final List<String> agents;
  final String selected;
  final ValueChanged<String> onSelect;
  final ThemeData theme;

  const _AgentSelector({
    required this.agents,
    required this.selected,
    required this.onSelect,
    required this.theme,
  });

  String _labelFor(String value) {
    if (value.isEmpty) return LocaleKeys.tabAgent.tr;
    return value[0].toUpperCase() + value.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        final other = agents.firstWhere(
          (a) => a != selected,
          orElse: () => selected,
        );
        onSelect(other);
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 28,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected == 'build'
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : context.appColors.chipBg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          _labelFor(selected),
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            height: 1.0,
            color: selected == 'build' ? theme.colorScheme.primary : null,
          ),
        ),
      ),
    );
  }
}

// ── Selector Chip ──

class _SelectorChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final ThemeData theme;
  final double maxWidth;

  const _SelectorChip({
    required this.label,
    required this.onTap,
    required this.theme,
    this.maxWidth = 100,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 28,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: context.appColors.chipBg,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              height: 1.0,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ),
    );
  }
}

// ── Attachments Bar ──

class _AttachmentsBar extends StatelessWidget {
  final List<String> files;
  final List<PickedImage> images;
  final ValueChanged<String> onRemoveFile;
  final ValueChanged<int> onRemoveImage;
  final VoidCallback? onDescribeImages;
  final bool describing;
  final String visionModelName;

  const _AttachmentsBar({
    required this.files,
    required this.images,
    required this.onRemoveFile,
    required this.onRemoveImage,
    this.onDescribeImages,
    this.describing = false,
    this.visionModelName = '',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTablet = isTabletLayout(context);

    if (files.isEmpty && images.isEmpty) return const SizedBox.shrink();

    Widget buildDescribeButton() {
      return InkWell(
        onTap: describing ? null : onDescribeImages,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.6,
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
              width: 0.5,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (describing)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    )
                  else
                    Icon(
                      Icons.auto_awesome,
                      size: 13,
                      color: theme.colorScheme.primary,
                    ),
                  const SizedBox(width: 4),
                  Text(
                    LocaleKeys.mobileImageToText.tr,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
              if (visionModelName.isNotEmpty) ...[
                const SizedBox(height: 2),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 100),
                  child: Text(
                    visionModelName,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 9.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    Widget buildImageAndFileList() {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ...images.asMap().entries.map((entry) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _ImageChip(
                  bytes: entry.value.bytes,
                  onRemove: () => onRemoveImage(entry.key),
                ),
              );
            }),
            ...files.map((path) {
              final name = path.split('\\').last.split('/').last;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.only(left: 8, right: 4),
                  decoration: BoxDecoration(
                    color: context.appColors.chipBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.4,
                      ),
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.paperclip,
                        size: 13,
                        color: theme.colorScheme.primary.withValues(alpha: 0.8),
                      ),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 130),
                        child: Text(
                          name,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      InkWell(
                        onTap: () => onRemoveFile(path),
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: Icon(
                            Icons.close_rounded,
                            size: 12,
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      );
    }

    final hasDescribeBtn = onDescribeImages != null;

    if (!hasDescribeBtn) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: buildImageAndFileList(),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (isTablet) ...[
            // 平板模式：转文字按钮锁定在最左侧，右侧为仅图片/文件可滚动的区域
            buildDescribeButton(),
            const SizedBox(width: 8),
            Expanded(child: buildImageAndFileList()),
          ] else ...[
            // 手机/非平板模式：图片/文件列表在左侧滚动，转文字按钮锁定在最右侧
            Expanded(child: buildImageAndFileList()),
            const SizedBox(width: 8),
            buildDescribeButton(),
          ],
        ],
      ),
    );
  }
}

// ── Image Chip ──

class _ImageChip extends StatefulWidget {
  final Uint8List bytes;
  final VoidCallback onRemove;

  const _ImageChip({required this.bytes, required this.onRemove});

  @override
  State<_ImageChip> createState() => _ImageChipState();
}

class _ImageChipState extends State<_ImageChip> {
  /// 全屏预览的解码宽度上限：屏幕短边逻辑像素 × devicePixelRatio × 4（预览
  /// 最大缩放倍数），即任何缩放级别下视口实际需要的最大物理分辨率。
  static int? _previewCacheWidth(BuildContext context) {
    final cap =
        (MediaQuery.sizeOf(context).shortestSide *
                MediaQuery.devicePixelRatioOf(context) *
                4)
            .round();
    return cap > 0 ? cap : null;
  }

  void _showPreview() {
    final theme = Theme.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: theme.colorScheme.surface,
        insetPadding: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: SizedBox(
          width: MediaQuery.sizeOf(ctx).width - 24,
          height: MediaQuery.sizeOf(ctx).height * 0.8,
          child: Stack(
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4,
                    child: Center(
                      child: Image.memory(
                        widget.bytes,
                        fit: BoxFit.contain,
                        // 预览最大只放大到 4x：按屏幕短边物理像素 × 4 封顶解码，
                        // 相机原图（12MP+）不再整幅解码造成内存尖峰。小图不受
                        // 影响（allowUpscaling 默认 false，低于封顶值按原尺寸解码）。
                        cacheWidth: _previewCacheWidth(ctx),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: theme.colorScheme.surface.withValues(
                      alpha: 0.7,
                    ),
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                  icon: Icon(
                    Icons.close_rounded,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: _showPreview,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                // 52px 缩略图无需全分辨率解码，限制缓存尺寸降内存。
                child: Image.memory(
                  widget.bytes,
                  fit: BoxFit.cover,
                  cacheWidth: 160,
                ),
              ),
            ),
            Positioned(
              top: 1,
              right: 1,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.onRemove,
                  borderRadius: BorderRadius.circular(9),
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.8),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.close_rounded,
                      size: 11,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Custom Popup Menu ──

class _PopupItem<T> {
  final T value;
  final String label;
  final bool selected;
  final bool enabled;
  final double height;
  final double fontSize;
  final TextAlign textAlign;
  final EdgeInsetsGeometry padding;

  const _PopupItem({
    required this.value,
    required this.label,
    this.selected = false,
    this.enabled = true,
    this.height = 28,
    this.fontSize = 11.5,
    this.textAlign = TextAlign.center,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
  });
}

/// 当前打开的自定义 Overlay 弹窗（模型/等级选择器）的关闭回调。
/// 非空时 Esc 优先关闭弹窗（见 _PromptInputState._onKeyEvent），而不是中止生成。
/// 假设：同一时刻只保留一个活跃弹窗（后开顶掉先开）；多 _PromptInputState
/// 实例（如多会话 PageView 缓存）共用该回调，后开实例的弹窗会关闭先开实例的，
/// 当前一次只交互一个输入框，可接受。
VoidCallback? _activePromptPopupDismiss;

void _closePromptPopup<T>(
  OverlayEntry entry,
  Completer<T?> completer, [
  T? result,
]) {
  try {
    if (entry.mounted) entry.remove();
  } catch (_) {
    // Overlay/Navigator 已 dispose 等极端情况：忽略移除异常，保证 future 仍能完成。
  }
  _activePromptPopupDismiss = null;
  if (!completer.isCompleted) completer.complete(result);
}

Future<T?> _showPopup<T>({
  required BuildContext context,
  required double left,
  required double top,
  required double width,
  required List<_PopupItem<T>> items,
}) {
  final theme = Theme.of(context);
  final appColors = context.appColors;
  final completer = Completer<T?>();

  // 桌面端：自绘标题栏 32px 在 Navigator/Overlay 上方，Overlay 原点不在
  // 全局 (0,0)。调用方传的是 localToGlobal 全局坐标，Positioned 要的是
  // 浮层局部坐标，必须减掉 Overlay 原点，否则弹窗整体下移约 32px。
  // 仅桌面转换，手机/平板保持原行为。
  double adjLeft = left;
  double adjTop = top;
  if (isDesktop) {
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlayBox != null) {
      final origin = overlayBox.localToGlobal(Offset.zero);
      adjLeft = left - origin.dx;
      adjTop = top - origin.dy;
    }
  }

  late OverlayEntry overlayEntry;
  overlayEntry = OverlayEntry(
    builder: (dialogContext) {
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => _closePromptPopup(overlayEntry, completer),
              behavior: HitTestBehavior.translucent,
            ),
          ),
          Positioned(
            left: adjLeft,
            top: adjTop,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              color: appColors.chipBg,
              child: Container(
                width: width,
                constraints: const BoxConstraints(maxHeight: 240),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.dividerColor.withValues(alpha: 0.25),
                    width: 0.5,
                  ),
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: items.map((item) {
                    return InkWell(
                      onTap: item.enabled
                          ? () => _closePromptPopup(
                              overlayEntry,
                              completer,
                              item.value,
                            )
                          : null,
                      child: Container(
                        height: item.height,
                        padding: item.padding,
                        alignment: Alignment.center,
                        child: Text(
                          item.label,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: item.fontSize,
                            fontWeight: item.selected
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: item.enabled
                                ? null
                                : theme.disabledColor.withValues(alpha: 0.4),
                          ),
                          textAlign: item.textAlign,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );

  // 后开的弹窗顶掉先开的：先关旧弹窗（完成其 future 为 null），再挂新弹窗。
  _activePromptPopupDismiss?.call();
  Overlay.of(context).insert(overlayEntry);
  _activePromptPopupDismiss = () => _closePromptPopup(overlayEntry, completer);
  return completer.future;
}

// ── Voice Input Button ──

class _VoiceInputButton extends StatefulWidget {
  final TextEditingController textController;
  final ValueChanged<String> onSendVoice;

  const _VoiceInputButton({
    required this.textController,
    required this.onSendVoice,
  });

  @override
  State<_VoiceInputButton> createState() => _VoiceInputButtonState();
}

class _VoiceInputButtonState extends State<_VoiceInputButton> {
  double _dragStartY = 0;

  VoiceInputController get _voiceCtrl =>
      Get.isRegistered<VoiceInputController>()
      ? Get.find<VoiceInputController>()
      : Get.put(VoiceInputController());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Obx(() {
      final isListening = _voiceCtrl.isListening.value;
      final isLongPress = _voiceCtrl.isLongPressMode.value;
      final isCancel = _voiceCtrl.isCancelZone.value;
      final modeActive = isListening || _voiceCtrl.isContinuousMode.value;

      Color btnColor;
      if (isLongPress && isCancel) {
        btnColor = Colors.redAccent;
      } else if (modeActive) {
        btnColor = theme.colorScheme.primary;
      } else {
        btnColor = theme.iconTheme.color ?? theme.colorScheme.onSurface;
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _voiceCtrl.toggleSingleTap(widget.textController);
        },
        onLongPressStart: (details) {
          _dragStartY = details.globalPosition.dy;
          _voiceCtrl.startLongPress();
        },
        onLongPressMoveUpdate: (details) {
          final dy = details.globalPosition.dy - _dragStartY;
          _voiceCtrl.updateDragZone(dy);
        },
        onLongPressEnd: (details) {
          _voiceCtrl.endLongPress(
            onSend: (text) {
              widget.onSendVoice(text);
            },
            onInsert: (text) {
              final currentText = widget.textController.text;
              final prefix =
                  currentText.isNotEmpty && !currentText.endsWith(' ')
                  ? '$currentText '
                  : currentText;
              widget.textController.text = '$prefix$text';
              widget.textController.selection = TextSelection.fromPosition(
                TextPosition(offset: widget.textController.text.length),
              );
            },
          );
        },
        onLongPressCancel: () {
          _voiceCtrl.cancelLongPress();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: AnimatedScale(
            scale: isListening ? 1.25 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: Icon(
              isListening ? Icons.mic : Icons.mic_none,
              size: 20,
              color: btnColor,
            ),
          ),
        ),
      );
    });
  }
}

// 日志查看入口已从工具栏移除，代码注释保留备用。
/*
/// 临时调试用：只读 Flutter 端日志文件，展示最后 100 行。后续会删除。
class _LogSheet extends StatefulWidget {
  const _LogSheet();

  @override
  State<_LogSheet> createState() => _LogSheetState();
}

class _LogSheetState extends State<_LogSheet> {
  static const int _maxLines = 100;

  String? _filePath;
  String _content = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });
    try {
      final dir = await AppLogger.getLogDir();
      final fileName = kDebugMode ? 'flutter_debug.log' : 'flutter.log';
      final file = File('$dir/$fileName');
      String content;
      String? path;
      if (await file.exists()) {
        final lines = await file.readAsLines();
        content = lines.length > _maxLines
            ? lines.sublist(lines.length - _maxLines).join('\n')
            : lines.join('\n');
        path = file.path;
      } else {
        content = '';
        path = file.path;
      }
      if (!mounted) return;
      setState(() {
        _filePath = path;
        _content = content;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _content = '读取日志失败: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Text(
                    '日志',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _filePath ?? '',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.textTheme.bodySmall?.color?.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: _load,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _content.isEmpty
                  ? Center(
                      child: Text(
                        '暂无日志',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        _content,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.4,
                          color: theme.textTheme.bodyMedium?.color?.withValues(
                            alpha: 0.85,
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
*/
