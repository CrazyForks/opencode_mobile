import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_app/utils/mention_rank.dart';

void main() {
  group('MentionRank & Ranking Tests', () {
    test('basenameOf extracts name correctly', () {
      expect(basenameOf('lib/main.dart'), 'main.dart');
      expect(basenameOf('lib/pages/home/'), 'home');
      expect(basenameOf('pubspec.yaml'), 'pubspec.yaml');
    });

    test('depthOf counts slashes correctly', () {
      expect(depthOf('pubspec.yaml'), 0);
      expect(depthOf('lib/main.dart'), 1);
      expect(depthOf('lib/pages/home/'), 2);
    });

    test('rankMentionEntries with empty query orders by depth', () {
      final entries = [
        'lib/pages/home/prompt_input.dart',
        'pubspec.yaml',
        'lib/main.dart',
        'lib/controllers/',
      ];
      final ranked = rankMentionEntries(entries: entries, query: '');
      expect(ranked.first.path, 'pubspec.yaml');
      expect(ranked[1].path, 'lib/controllers/');
      expect(ranked[2].path, 'lib/main.dart');
      expect(ranked[3].path, 'lib/pages/home/prompt_input.dart');
    });

    test('rankMentionEntries matches query and highlights basename', () {
      final entries = [
        'lib/pages/home/prompt_input.dart',
        'lib/controllers/session_controller.dart',
        'lib/controllers/tablet_tool_controller.dart',
      ];
      final ranked = rankMentionEntries(entries: entries, query: 'prompt');
      expect(ranked.isNotEmpty, true);
      expect(ranked.first.path, 'lib/pages/home/prompt_input.dart');
      expect(ranked.first.baseIndices.isNotEmpty, true);
    });

    test('trailing slash prioritizes directory match', () {
      final entries = [
        'lib/pages/home/prompt_input.dart',
        'lib/pages/',
        'lib/controllers/',
      ];
      final ranked = rankMentionEntries(entries: entries, query: 'pages/');
      expect(ranked.first.path, 'lib/pages/');
      expect(ranked.first.isDir, true);
    });
  });
}
