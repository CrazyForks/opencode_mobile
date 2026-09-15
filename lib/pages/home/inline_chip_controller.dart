import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../utils/mention_parse.dart';
import '../../utils/mention_rank.dart';

/// 把输入框草稿里的 `@路径` 渲染成美观交互胶囊的 TextEditingController。
///
/// 具备：
/// 1. 正则匹配 `@[^\s@]+`，行内渲染为包含文件/目录图标与简短名称的标签胶囊（WidgetSpan）；
/// 2. 补齐 `\u200b`（零宽字符）确保输入框真实字符串与光标位置偏移严格对齐；
/// 3. 点击胶囊回调 [onChipTap]，可在侧边栏或工作台即时定位/预览该文件；
/// 4. 退格/删除原子化防护：删除光标碰触胶囊时整块清除，防止误留半截残损路径。
class InlineChipTextEditingController extends TextEditingController {
  InlineChipTextEditingController({
    required this.onChipTap,
    super.text,
  });

  /// 点击胶囊回调，参数为 `@` 后的工作区相对路径。
  final void Function(String relativePath) onChipTap;

  /// 从建议菜单插入的胶囊范围（`@路径`）。
  final List<TextRange> _chipRanges = [];

  /// 注册一个从建议列表插入的胶囊范围。
  void registerChip(int start, int end) {
    _chipRanges.add(TextRange(start: start, end: end));
    _chipRanges.sort((a, b) => a.start.compareTo(b.start));
  }

  /// 文本变化后更新胶囊位置。
  void _recalcRanges(String oldText, String newText) {
    if (_chipRanges.isEmpty) return;

    var commonPrefix = 0;
    final minLen = oldText.length < newText.length
        ? oldText.length
        : newText.length;
    while (commonPrefix < minLen &&
        oldText[commonPrefix] == newText[commonPrefix]) {
      commonPrefix++;
    }

    final diff = newText.length - oldText.length;
    final updated = <TextRange>[];

    for (final range in _chipRanges) {
      if (range.end <= commonPrefix) {
        updated.add(range);
      } else if (range.start >= commonPrefix) {
        final newStart = range.start + diff;
        final newEnd = range.end + diff;
        if (newStart >= 0 && newEnd <= newText.length) {
          updated.add(TextRange(start: newStart, end: newEnd));
        }
      }
    }

    _chipRanges
      ..clear()
      ..addAll(updated);
  }

  @override
  set value(TextEditingValue newValue) {
    if (newValue.text.isEmpty) {
      _chipRanges.clear();
      super.value = newValue;
      return;
    }
    final oldVal = value;

    // 当文本缩短（删除或替换操作）时，检查是否切入已登记胶囊区间
    if (newValue.text.length < oldVal.text.length) {
      final oldSel = oldVal.selection;
      final newSel = newValue.selection;

      if (oldSel.isValid && newSel.isValid) {
        int delStart, delEnd;

        if (!oldSel.isCollapsed) {
          delStart = oldSel.start;
          delEnd = oldSel.end;
        } else if (newSel.isCollapsed && newSel.start < oldSel.start) {
          delStart = newSel.start;
          delEnd = oldSel.start;
        } else {
          delStart = oldSel.start;
          delEnd = oldSel.start + (oldVal.text.length - newValue.text.length);
        }

        if (delStart < delEnd) {
          var actualDelStart = delStart;
          var actualDelEnd = delEnd;
          final indicesToRemove = <int>[];

          for (var i = 0; i < _chipRanges.length; i++) {
            final range = _chipRanges[i];
            // 若删除范围碰到了胶囊范围，直接扩展为把整颗胶囊完整删除
            if (actualDelStart < range.end && actualDelEnd > range.start) {
              if (range.start < actualDelStart) {
                actualDelStart = range.start;
              }
              if (range.end > actualDelEnd) {
                actualDelEnd = range.end;
              }
              indicesToRemove.add(i);
            }
          }

          if (indicesToRemove.isNotEmpty) {
            for (var i = indicesToRemove.length - 1; i >= 0; i--) {
              _chipRanges.removeAt(indicesToRemove[i]);
            }

            final before = oldVal.text.substring(
              0,
              actualDelStart.clamp(0, oldVal.text.length),
            );
            final after = oldVal.text.substring(
              actualDelEnd.clamp(0, oldVal.text.length),
            );
            newValue = TextEditingValue(
              text: before + after,
              selection: TextSelection.collapsed(
                offset: actualDelStart.clamp(0, before.length + after.length),
              ),
            );
          }
        }
      }
    }

    super.value = newValue;
    _recalcRanges(oldVal.text, newValue.text);
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = this.text;
    final spans = <InlineSpan>[];

    final regex = RegExp(r'@([^\s@]+)');
    var lastIndex = 0;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    for (final match in regex.allMatches(text)) {
      // 边界判定与发送侧共用 mention_parse，避免邮箱误转胶囊
      if (match.start > 0) {
        if (!isMentionBoundary(text[match.start - 1])) {
          continue;
        }
      }

      // 尾标点不进胶囊：`@a.md,` 只渲染 `a.md`
      var token = stripMentionTrailer(match.group(1)!);
      // `#` 行号后缀不进胶囊显示
      final hash = token.indexOf('#');
      if (hash > 0 &&
          RegExp(r'^[Ll]?\d+(-\d+)?$').hasMatch(token.substring(hash + 1))) {
        token = token.substring(0, hash);
      }
      if (token.isEmpty) {
        continue;
      }

      // 胶囊只覆盖 `@` + 干净路径；尾标点 / `#行号` 留作普通文本，避免零宽对齐错位
      final chipEnd = match.start + 1 + token.length;

      if (match.start > lastIndex) {
        spans.add(
          TextSpan(text: text.substring(lastIndex, match.start), style: style),
        );
      }

      final relativePath = token;
      final isDir = relativePath.endsWith('/') || relativePath.endsWith('\\');
      final rawBase = basenameOf(relativePath);
      final filename = isDir ? '$rawBase/' : rawBase;

      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: GestureDetector(
            onTap: () => onChipTap(relativePath),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF2A2B36)
                      : const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF3F4152)
                        : const Color(0xFFCBD5E1),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isDir ? CupertinoIcons.folder : CupertinoIcons.doc_text,
                      size: 12,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                    const SizedBox(width: 3),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: Text(
                        filename,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: isDark ? Colors.white70 : Colors.black87,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final replacedLength = chipEnd - match.start;
      if (replacedLength > 1) {
        spans.add(
          TextSpan(
            text: '\u200b' * (replacedLength - 1),
            style: style?.copyWith(fontSize: 0, letterSpacing: 0),
          ),
        );
      }

      lastIndex = chipEnd;
    }

    if (lastIndex < text.length) {
      spans.add(TextSpan(text: text.substring(lastIndex), style: style));
    }

    return TextSpan(children: spans, style: style);
  }
}
