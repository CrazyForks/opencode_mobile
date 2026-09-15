import 'dart:async';
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import '../api/endpoints.dart';
import '../api/opencode_client.dart';
import '../controllers/project_controller.dart';
import '../controllers/tablet_tool_controller.dart';
import '../utils/app_logger.dart';
import '../utils/mention_rank.dart';

/// 解析 `GET /find/file` 载荷。
///
/// 后端 `findFile` 返回 `string[]`（见
/// `clone/opencode/packages/opencode/src/server/routes/instance/httpapi/handlers/file.ts:43-60`
/// 与 `openapi.json`）；此处额外兼容对象形 `{path: ...}`（`GET /file` 的
/// `FileNode` / 新版 `file.find:{path,type}`），避免 `toString()` 得到
/// `[object Object]`。
List<String> parseFindFilePayload(dynamic data) {
  final rawList = (data is Map && data['data'] is List)
      ? data['data'] as List
      : data is List
      ? data
      : const [];
  final out = <String>[];
  for (final e in rawList) {
    if (e is String) {
      if (e.isNotEmpty) out.add(e);
    } else if (e is Map && e['path'] is String) {
      final p = e['path'] as String;
      if (p.isNotEmpty) out.add(p);
    }
  }
  return out;
}

/// @ 提及候选服务：负责与 OpenCode 后端 `GET /find/file` 交互，并结合本地模糊打分。
class MentionSearchService {
  final OpenCodeClient _client = OpenCodeClient();
  CancelToken? _cancelToken;
  int _requestSeq = 0;

  /// 本地查询缓存（key: worktree+query, value: entries）
  final Map<String, List<String>> _cache = {};

  void dispose() {
    _cancelToken?.cancel('mention_service_disposed');
  }

  /// 搜索文件与文件夹，返回排序和高亮计算后的候选列表。
  Future<List<MentionRankRow>> search(String query) async {
    final worktree = Get.isRegistered<ProjectController>()
        ? Get.find<ProjectController>().activeProject.value?.worktree
        : null;

    final seq = ++_requestSeq;
    _cancelToken?.cancel('new_mention_search');
    final token = CancelToken();
    _cancelToken = token;

    final trimmed = query.trim();

    // 收集最近打开/正在编辑的文件，优先置顶
    final recentEntries = <String>[];
    if (Get.isRegistered<TabletToolController>()) {
      final toolCtrl = Get.find<TabletToolController>();
      for (final f in toolCtrl.openedFiles) {
        if (f.path.isNotEmpty && !recentEntries.contains(f.path)) {
          recentEntries.add(f.path);
        }
      }
    }

    final cacheKey = '${worktree ?? ''}_$trimmed';
    List<String> rawEntries;

    if (_cache.containsKey(cacheKey)) {
      rawEntries = _cache[cacheKey]!;
    } else {
      try {
        final response = await _client.get(
          ApiEndpoints.findFile,
          queryParameters: {
            'query': trimmed,
            'limit': 50,
          },
          directory: worktree,
          cancelToken: token,
        );

        if (seq != _requestSeq) return const [];

        if (response.statusCode == 200) {
          rawEntries = parseFindFilePayload(response.data);
          // 仅缓存非空前缀的结果，数量控制在 100 以内
          if (_cache.length > 100) _cache.clear();
          _cache[cacheKey] = rawEntries;
        } else {
          rawEntries = const [];
        }
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) {
          return const [];
        }
        AppLogger.w('Mention search failed: $e');
        rawEntries = const [];
      }
    }

    // 合并最近文件与后端搜索结果，并去重
    final merged = <String>[];
    for (final r in recentEntries) {
      if (!merged.contains(r)) merged.add(r);
    }
    for (final e in rawEntries) {
      if (!merged.contains(e)) merged.add(e);
    }

    return rankMentionEntries(
      entries: merged,
      query: trimmed,
      limit: 30,
    );
  }
}
