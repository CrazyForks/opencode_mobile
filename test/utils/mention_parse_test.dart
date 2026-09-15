import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_app/utils/mention_parse.dart';

void main() {
  group('mention_parse', () {
    test('strips trailing punctuation', () {
      expect(parseMentions('@lib/a.md, 看下').single.path, 'lib/a.md');
      expect(parseMentions('请看@a/b。').single.path, 'a/b');
      expect(parseMentions('(@lib/main.dart)').single.path, 'lib/main.dart');
    });

    test('skips email and backtick code, matches after CJK', () {
      expect(parseMentions('mail user@test.com'), isEmpty);
      expect(parseMentions('`@lib/a.dart`'), isEmpty);
      expect(parseMentions('a@b'), isEmpty);
      // 服务端 FILE_REGEX 同样展开：中文/斜杠之后视为边界
      expect(parseMentions('请看@a/b。').single.path, 'a/b');
      expect(parseMentions('foo/@bar').single.path, 'bar');
    });

    test('paren boundary triggers', () {
      expect(isMentionBoundary('('), isTrue);
      expect(isMentionBoundary(' '), isTrue);
      expect(isMentionBoundary(null), isTrue);
      expect(isMentionBoundary('看'), isTrue);
      expect(isMentionBoundary('a'), isFalse);
      expect(isMentionBoundary('`'), isFalse);
      expect(isMentionBoundary('@'), isFalse);
      expect(parseMentions('(@lib/main.dart)').single.path, 'lib/main.dart');
    });

    test('splits # line range', () {
      final refs = parseMentions('@lib/a.dart#L10-20 看下');
      expect(refs.single.path, 'lib/a.dart');
      expect(refs.single.lineRange, 'L10-20');
    });

    test('dedups', () {
      expect(parseMentions('@a/b @a/b').length, 1);
    });

    test('cuts at brackets mid-token', () {
      expect(
        parseMentions('(@lib/main.dart)，看下').single.path,
        'lib/main.dart',
      );
    });
  });

  group('parseDisplayMentions', () {
    test('dir mention yields basename label with offsets', () {
      final segs = parseDisplayMentions('@lib/ 回复你好');
      expect(segs.length, 1);
      expect(segs.single.start, 0);
      expect(segs.single.end, '@lib/'.length);
      expect(segs.single.path, 'lib/');
      expect(segs.single.label, 'lib');
      expect(segs.single.targetLine, isNull);
    });

    test('file mention with line range shows start line', () {
      final segs = parseDisplayMentions('看下 @lib/a.dart#L10-20 谢谢');
      expect(segs.length, 1);
      expect(segs.single.path, 'lib/a.dart');
      expect(segs.single.label, 'a.dart L10');
      expect(segs.single.targetLine, 10);
    });

    test('trailing punctuation excluded from span', () {
      final segs = parseDisplayMentions('(@lib/main.dart)，看下');
      expect(segs.length, 1);
      expect(segs.single.path, 'lib/main.dart');
      expect(segs.single.label, 'main.dart');
    });

    test('email yields nothing', () {
      expect(parseDisplayMentions('mail user@test.com'), isEmpty);
    });
  });

  group('isFileCoveredByMentions', () {
    test('dir filename matches dir mention', () {
      expect(
        isFileCoveredByMentions(
          filename: 'lib',
          url: 'file:///project/lib',
          mime: 'application/x-directory',
          mentionPaths: const ['lib/'],
        ),
        isTrue,
      );
    });

    test('deep mention matches by basename or url suffix', () {
      expect(
        isFileCoveredByMentions(
          filename: 'main.dart',
          url: 'file:///project/lib/main.dart',
          mime: 'text/plain',
          mentionPaths: const ['lib/main.dart'],
        ),
        isTrue,
      );
    });

    test('unrelated mention does not cover', () {
      expect(
        isFileCoveredByMentions(
          filename: 'main.dart',
          url: 'file:///project/lib/main.dart',
          mime: 'text/plain',
          mentionPaths: const ['lib/other.dart'],
        ),
        isFalse,
      );
    });

    test('images and data urls are never covered', () {
      expect(
        isFileCoveredByMentions(
          filename: 'a.png',
          url: 'file:///project/a.png',
          mime: 'image/png',
          mentionPaths: const ['a.png'],
        ),
        isFalse,
      );
      expect(
        isFileCoveredByMentions(
          filename: '',
          url: 'data:image/png;base64,xxx',
          mime: 'image/png',
          mentionPaths: const [],
        ),
        isFalse,
      );
    });
  });
}
