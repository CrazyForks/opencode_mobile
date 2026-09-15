import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_app/api/models/message.dart';

MessageModel buildUserMessage(List<Map<String, dynamic>> parts) {
  return MessageModel.fromJson({
    'id': 'msg-1',
    'sessionID': 'ses-1',
    'role': 'user',
    'parts': parts,
  });
}

Map<String, dynamic> textPart(String id, String text,
    {bool synthetic = false, bool ignored = false}) {
  return {
    'id': id,
    'type': 'text',
    'text': text,
    if (synthetic) 'synthetic': true,
    if (ignored) 'ignored': true,
  };
}

Map<String, dynamic> filePart(String id) {
  return {
    'id': id,
    'type': 'file',
    'url': 'file:///project/lib/main.dart',
    'mime': 'text/plain',
    'filename': 'main.dart',
  };
}

void main() {
  group('userDisplayText filters backend-expanded synthetic parts', () {
    test('returns original prompt, not file content', () {
      final msg = buildUserMessage([
        textPart('prt-1', '@lib/main.dart 看下這個文件'),
        textPart('prt-2',
            'Called the Read tool with the following input: {"filePath": "/project/lib/main.dart"}',
            synthetic: true),
        textPart('prt-3', 'void main() {\n  runApp(App());\n}',
            synthetic: true),
        filePart('prt-4'),
      ]);

      expect(msg.userDisplayText, '@lib/main.dart 看下這個文件');
      expect(msg.userDisplayText, isNot(contains('void main')));
      expect(msg.userDisplayText, isNot(contains('Called the Read tool')));
    });

    test('ignores ignored parts too', () {
      final msg = buildUserMessage([
        textPart('prt-1', 'hello', ignored: true),
        textPart('prt-2', 'real prompt'),
      ]);

      expect(msg.userDisplayText, 'real prompt');
    });

    test('returns empty when only synthetic parts exist', () {
      final msg = buildUserMessage([
        textPart('prt-1', 'file content here', synthetic: true),
        filePart('prt-2'),
      ]);

      expect(msg.userDisplayText, isEmpty);
    });

    test('plain message without synthetic is unchanged', () {
      final msg = buildUserMessage([
        textPart('prt-1', 'just a normal question'),
      ]);

      expect(msg.userDisplayText, 'just a normal question');
    });

    test('Part exposes synthetic/ignored flags', () {
      final msg = buildUserMessage([
        textPart('prt-1', 'a', synthetic: true),
        textPart('prt-2', 'b', ignored: true),
        textPart('prt-3', 'c'),
      ]);

      expect(msg.parts[0].isSynthetic, isTrue);
      expect(msg.parts[1].isIgnored, isTrue);
      expect(msg.parts[2].isSynthetic, isFalse);
      expect(msg.parts[2].isIgnored, isFalse);
    });
  });
}
