// @ 提及解析唯一真相源：三处共用（输入框联想触发、全文提取发送、胶囊渲染）。
//
// 对齐后端语义：
// - 边界：服务端 config/markdown.ts:5 FILE_REGEX 为准，`@` 前不是 ASCII 单词
//   字符、反引号或 `@` 即触发（中文请看@a/b 会命中，user@test.com 不会）。
//   服务端对不存在路径静默丢弃，客户端与服务端一致即可。
// - 尾标点剥离 `build-request-parts.ts:46` `replace(/[.,!?;:)}\]"']+$/, "")`，
//   另加 `,`、`.` 与中文标点（服务端 FILE_REGEX 天然排除空格/反引号/逗号，
//   尾 `.`/`,` 自动剥离，见 `config/markdown.test.ts`）。
// - `#` 行号：兼容 TUI `path#L10(-20)` 写法，拆出 lineRange 供发送侧转 `?start/end`。

import 'mention_rank.dart';

/// 一条 @ 提及。
class MentionRef {
  const MentionRef({
    required this.path,
    required this.isDir,
    this.lineRange = '',
  });

  /// 干净路径（已剥尾标点、已拆出行号；目录保留尾部 `/` 或 `\`）。
  final String path;

  /// 是否目录（尾部 `/` 或 `\`）。
  final bool isDir;

  /// 行号后缀（`12` / `L12` / `L10-20`，不含 `#`），无则 `''`。
  final String lineRange;
}

/// 是否允许在 [prevChar] 之后触发 @ 提及。[prevChar] 为 null 表示行首。
/// 对齐服务端 FILE_REGEX（config/markdown.ts:5，`@` 前不能是 ASCII 单词字符或
/// 反引号）：前一字符不是 [A-Za-z0-9_]、反引号或 `@` 即视为边界。中文
/// （请看@a/b）、emoji、空白、标点、`/` 之后都触发；user@test.com、
/// 反引号包裹的代码则跳过。
bool isMentionBoundary(String? prevChar) {
  if (prevChar == null) return true;
  return RegExp(r'[^\w`@]').hasMatch(prevChar);
}

/// 剥离提及尾部标点（英文 `.,!?;:)}\]"',.` + 中文 `，。；：！？、`）。
String stripMentionTrailer(String s) =>
    s.replaceAll(RegExp(r'''[.,!?;:)}\]"',.，。；：！？、]+$'''), '');

/// 在原文 match 中截断提及头：空白/`@`/反引号/括号引号处结束。
///
/// 这些字符几乎不会出现在真实相对路径里，但 prose 包裹很常见：`(@a/b)`、
/// `"@a/b"`。CJK/中文标点保留（CJK 文件名合法；真解析失败服务端静默丢弃）。
/// 发送侧与展示侧共用，保证两边认的是同一个提及。
String cutMentionHead(String s) {
  final idx = s.indexOf(RegExp(r'''[\s@`()\[\]{}<>"']'''));
  return idx < 0 ? s : s.substring(0, idx);
}

final _mentionRegex = RegExp(r'@([^\s@]+)');
final _lineRangeSuffix = RegExp(r'^[Ll]?\d+(-\d+)?$');

/// 展示用的一段 @ 提及（含原文起止偏移，供气泡内联高亮）。
class DisplayMentionSegment {
  const DisplayMentionSegment({
    required this.start,
    required this.end,
    required this.path,
    required this.label,
    this.targetLine,
  });

  /// `@` 在原文中的起始偏移（含 `@`）。
  final int start;

  /// 提及 token 在原文中的结束偏移（不含尾标点；含 `#行号` 后缀）。
  final int end;

  /// 干净路径（已剥尾标点、已拆出行号；目录保留尾部 `/`）。
  final String path;

  /// 内联显示文本：basename + 可选 ` L<起始行>`（对齐参考端）。
  final String label;

  /// 起始行号（`#L10-20`/`#12` → 10/12），无则 null。
  final int? targetLine;
}

/// 提取展示用 @ 提及（带偏移，不去重，顺序返回）。
///
/// 与 [parseMentions] 同一套边界/尾标点/`#行号` 语义；区别是保留原文位置，
/// 供 `Text.rich` 把 `@长路径` 原地替换为短 [DisplayMentionSegment.label]。
/// 参考端对应逻辑：`opencode_flutter/.../chat/message_bubble.dart`
/// `_buildHighlightedText`（basename 蓝色高亮 + 点击打开文件）。
List<DisplayMentionSegment> parseDisplayMentions(String text) {
  final out = <DisplayMentionSegment>[];
  for (final m in _mentionRegex.allMatches(text)) {
    if (m.start > 0 && !isMentionBoundary(text[m.start - 1])) continue;
    final token = stripMentionTrailer(cutMentionHead(m.group(1)!));
    var path = token;
    int? targetLine;
    final hash = token.indexOf('#');
    if (hash > 0) {
      final maybeRange = token.substring(hash + 1);
      if (_lineRangeSuffix.hasMatch(maybeRange)) {
        path = token.substring(0, hash);
        targetLine = int.tryParse(
          RegExp(r'\d+').firstMatch(maybeRange)?.group(0) ?? '',
        );
      }
    }
    if (path.isEmpty) continue;
    final base = basenameOf(path);
    if (base.isEmpty) continue;
    out.add(
      DisplayMentionSegment(
        start: m.start,
        end: m.start + 1 + token.length,
        path: path,
        label: targetLine != null ? '$base L$targetLine' : base,
        targetLine: targetLine,
      ),
    );
  }
  return out;
}

/// file part 是否已被正文内联提及覆盖。
///
/// 覆盖则气泡上方不再重复显示该 chip（内联 basename 已足够）；未覆盖
///（如 📎 直传附件、正文没写 `@`）则 chip 保留，否则附件彻底不可见。
/// 图片与 data-URL 附件永远不视为覆盖（它们没有 `@` 文本表示）。
/// [mentionPaths] 取自同条消息正文的 [parseDisplayMentions] 全体 path。
bool isFileCoveredByMentions({
  required String filename,
  required String url,
  required String mime,
  required List<String> mentionPaths,
}) {
  if (mime.startsWith('image/') || url.startsWith('data:')) return false;
  final name = _normalizeMentionPath(filename);
  var urlPath = '';
  if (url.isNotEmpty) {
    try {
      urlPath = _normalizeMentionPath(Uri.decodeFull(Uri.parse(url).path));
    } catch (_) {
      urlPath = '';
    }
  }
  if (name.isEmpty && urlPath.isEmpty) return false;
  for (final rawMention in mentionPaths) {
    final m = _normalizeMentionPath(rawMention);
    if (m.isEmpty) continue;
    final base = m.split('/').last;
    if (name.isNotEmpty &&
        (m == name || m.endsWith('/$name') || name == base)) {
      return true;
    }
    if (urlPath.isNotEmpty &&
        (urlPath == m || urlPath.endsWith('/$m'))) {
      return true;
    }
  }
  return false;
}

/// 路径归一：反斜杠转正斜杠，去尾部斜杠（目录 `lib/` 与 filename `lib` 视为同一）。
String _normalizeMentionPath(String s) =>
    s.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');

/// 从全文提取去重后的 @ 提及。跳过邮箱（边界检查），跳过空 token。
List<MentionRef> parseMentions(String text) {
  final out = <MentionRef>[];
  final seen = <String>{};
  for (final m in _mentionRegex.allMatches(text)) {
    if (m.start > 0 && !isMentionBoundary(text[m.start - 1])) continue;
    var token = stripMentionTrailer(cutMentionHead(m.group(1)!));
    if (token.isEmpty || !seen.add(token)) continue;
    // `#` 行号拆分：`path#L10` / `path#L10-20` / `path#12`。
    var lineRange = '';
    final hash = token.indexOf('#');
    if (hash > 0) {
      final maybeRange = token.substring(hash + 1);
      if (_lineRangeSuffix.hasMatch(maybeRange)) {
        lineRange = maybeRange;
        token = token.substring(0, hash);
      }
    }
    if (token.isEmpty) continue;
    out.add(
      MentionRef(
        path: token,
        isDir: token.endsWith('/') || token.endsWith(r'\'),
        lineRange: lineRange,
      ),
    );
  }
  return out;
}
