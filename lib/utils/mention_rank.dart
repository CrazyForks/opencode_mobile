// @ 提及的本地搜索排序纯函数：
// 支持子序列边界命中打分、文件名（basename）加分、目录尾斜杠感知与深度排序。
// 条目 = 目录（尾部 `/`，优先）+ 文件；空 query 按深度排序取前 limit；
// 有 query 时 basename 子序列命中 +3 分，含 `/` 的 query 匹配完整路径。

/// 一条排序后的候选。
class MentionRankRow {
  const MentionRankRow({
    required this.path,
    required this.score,
    required this.baseIndices,
  });

  /// 工作区相对路径（目录保留尾部 `/`）。
  final String path;

  /// 排序分（越高越靠前）。
  final int score;

  /// 命中字符在 basename 内的位置（用于高亮；纯文件名匹配时为该文件名的命中位）。
  final List<int> baseIndices;

  bool get isDir => path.endsWith('/') || path.endsWith('\\');
}

/// 子序列打分结果。
class _PathScore {
  const _PathScore(this.score, this.indices);

  final int score;
  final List<int> indices;
}

/// 子序列打分：边界命中（行首或 `/ - _ . 空格` 之后）+4、其余 +2、连续命中 +1；
/// 任一字符缺失返回 null。两参数均已小写。
_PathScore? _scorePath(String path, String query) {
  var pi = 0;
  var score = 0;
  final indices = <int>[];
  for (var qi = 0; qi < query.length; qi++) {
    final ch = query[qi];
    var found = -1;
    for (var i = pi; i < path.length; i++) {
      if (path[i] == ch) {
        found = i;
        break;
      }
    }
    if (found < 0) return null;
    if (found == pi && qi > 0) score += 1;
    final prev = found > 0 ? path[found - 1] : '';
    final boundary =
        found == 0 ||
        prev == '/' ||
        prev == '\\' ||
        prev == '-' ||
        prev == '_' ||
        prev == '.' ||
        prev == ' ';
    score += boundary ? 4 : 2;
    indices.add(found);
    pi = found + 1;
  }
  return _PathScore(score, indices);
}

/// basename（尾部 `/` 先去除）。
String basenameOf(String path) {
  final text = path.replaceAll(RegExp(r'[/\\]+$'), '');
  final at = text.replaceAll('\\', '/').lastIndexOf('/');
  return at < 0 ? text : text.substring(at + 1);
}

/// 路径深度（目录尾斜杠不计）。
int depthOf(String path) {
  final text = path.replaceAll(RegExp(r'[/\\]+$'), '');
  var count = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == '/' || text[i] == '\\') count++;
  }
  return count;
}

/// 对目录+文件条目排序，返回前 [limit] 条。
List<MentionRankRow> rankMentionEntries({
  required List<String> entries,
  required String query,
  int limit = 30,
}) {
  if (query.isEmpty) {
    final sorted =
        entries
            .map(
              (path) =>
                  MentionRankRow(path: path, score: 0, baseIndices: const []),
            )
            .toList()
          ..sort((a, b) {
            final byDepth = depthOf(a.path).compareTo(depthOf(b.path));
            return byDepth != 0
                ? byDepth
                : a.path.toLowerCase().compareTo(b.path.toLowerCase());
          });
    return sorted.take(limit).toList();
  }

  final q = query.toLowerCase();
  final slash = q.contains('/') || q.contains('\\');
  final dirSlashQuery = q.endsWith('/') || q.endsWith('\\');
  // 尾斜杠查询是目录专用：目录匹配时去掉尾斜杠，并给目录加分。
  final dirQ = dirSlashQuery ? q.substring(0, q.length - 1) : q;
  final rows = <MentionRankRow>[];
  for (final entry in entries) {
    final isDir = entry.endsWith('/') || entry.endsWith('\\');
    final clean = entry.replaceAll(RegExp(r'[/\\]+$'), '');
    final lower = clean.toLowerCase();
    if (!slash) {
      final base = basenameOf(lower);
      final bs = _scorePath(base, q);
      if (bs != null) {
        rows.add(
          MentionRankRow(
            path: entry,
            score: bs.score + 3,
            baseIndices: bs.indices,
          ),
        );
        continue;
      }
    }
    final matchQ = isDir && dirSlashQuery ? dirQ : q;
    final full = _scorePath(lower.replaceAll('\\', '/'), matchQ.replaceAll('\\', '/'));
    if (full != null) {
      final normalizedLower = lower.replaceAll('\\', '/');
      final baseStart = normalizedLower.lastIndexOf('/') + 1;
      rows.add(
        MentionRankRow(
          path: entry,
          score: full.score,
          baseIndices: full.indices
              .where((i) => i >= baseStart)
              .map((i) => i - baseStart)
              .toList(),
        ),
      );
    }
  }
  rows.sort((a, b) {
    // 尾斜杠查询是目录意图：目录行无条件置前
    if (dirSlashQuery && a.isDir != b.isDir) {
      return a.isDir ? -1 : 1;
    }
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final byDepth = depthOf(a.path).compareTo(depthOf(b.path));
    return byDepth != 0
        ? byDepth
        : a.path.toLowerCase().compareTo(b.path.toLowerCase());
  });
  return rows.take(limit).toList();
}
