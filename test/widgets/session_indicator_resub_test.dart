import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:opencode_app/controllers/session_controller.dart';
import 'package:opencode_app/init.dart';
import 'package:opencode_app/pages/home/session_indicator.dart';
import 'package:opencode_app/utils/app_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    Global.settings = AppSettingsStore(prefs);
    Get.reset();
  });

  tearDown(() {
    Get.reset();
  });

  testWidgets(
    'SessionIndicator blinks again after runState instance is replaced',
    (tester) async {
      final sessionCtrl = Get.put(SessionController());
      sessionCtrl.openedSessionIds.assignAll(['s1', 's2']);

      Future<void> pumpIndicator() async {
        await tester.pumpWidget(
          GetMaterialApp(
            home: Scaffold(
              body: SessionIndicator(
                openedIds: const ['s1', 's2'],
                activeId: 's2',
                onTap: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await pumpIndicator();

      // 发光分支的 AnimatedBuilder（listenable 为 blink 动画）；
      // SingleChildScrollView 的 overscroll 指示器也是 AnimatedBuilder
      //（listenable 为 _StretchController/ChangeNotifier），需排除。
      Finder glowFinder() => find.descendant(
        of: find.byType(SessionIndicator),
        matching: find.byWidgetPredicate(
          (w) => w is AnimatedBuilder && w.listenable is! ChangeNotifier,
        ),
      );

      // 初始无待办：后台 dot 不发光
      expect(glowFinder(), findsNothing);

      // 模拟“关闭后重开同一会话”：丢弃实例 A，新建实例 B 并重建 UI
      //（ValueKey(s1) 复用同一个 _SessionDotState）。
      sessionCtrl.sessionRuntimeStates.remove('s1');
      final stateB = sessionCtrl.stateOf('s1');
      await pumpIndicator();

      // 新实例出现待办：后台 dot 应开始 requiresAction 闪烁（发光分支）
      stateB.hasPendingQuestion.value = true;
      await tester.pump();

      expect(glowFinder(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
