import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../../init.dart';
import '../layout_utils.dart';

/// Adapter class for configuring desktop window dimensions, window options,
/// restoration bounds (maximize states), and centering parameters using `window_manager`.
class WindowsAdapter {
  /// 持久化窗口坐标的合法区间（Win32 虚拟屏坐标合理域）。
  /// 仅用于识别损坏数据，必须足够宽以容纳多显示器负坐标。
  static const double _minWindowCoord = -32000;
  static const double _maxWindowCoord = 32000;

  static Future<void> setSize() async {
    if (!isDesktop) return;

    await windowManager.ensureInitialized();

    // 拦截原生关闭信号，使 TitleBarController.onWindowClose 能执行
    // sidecar 清理；否则点系统 X / Alt+F4 会直接退出留下孤儿进程。
    await windowManager.setPreventClose(true);

    final isMax = Global.settings.isMax;
    final windowSize = Global.settings.windowSize;
    final windowPosition = Global.settings.windowPosition;
    final onTop = Global.settings.onTop;

    // 安全解析窗口尺寸，防止存储数据损坏导致崩溃
    Size? safeSize;
    if (windowSize.length >= 2) {
      final w = double.tryParse(windowSize[0]);
      final h = double.tryParse(windowSize[1]);
      if (w != null && h != null && w > 0 && h > 0) {
        safeSize = Size(w, h);
      }
    }

    WindowOptions windowOptions = WindowOptions(
      size: safeSize,
      minimumSize: const Size(800, 500),
      center: windowPosition.isEmpty,
      backgroundColor: Colors.transparent,
      alwaysOnTop: onTop,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden, // Frameless custom title bar
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      if (!isMax) {
        if (safeSize != null) {
          await windowManager.setSize(safeSize);
        }
        bool positionRestored = false;
        if (windowPosition.length >= 2) {
          final x = double.tryParse(windowPosition[0]);
          final y = double.tryParse(windowPosition[1]);
          // 校验只用于拦截明显损坏的持久化数据，不能收窄合法范围：
          // 多显示器下副屏位于主屏左侧 / 上方时坐标为负（1920 宽副屏在左
          // 时 x 可达 -1920），过严的下限会把合法位置误判为非法。
          // 这里取 Win32 虚拟屏坐标的合理域。
          if (x != null &&
              y != null &&
              x >= _minWindowCoord &&
              y >= _minWindowCoord &&
              x <= _maxWindowCoord &&
              y <= _maxWindowCoord) {
            await windowManager.setPosition(Offset(x, y));
            positionRestored = true;
          }
        }
        // 位置缺失或损坏时兜底居中，避免既不恢复也不居中、
        // 窗口落到 OS 默认位置。
        if (!positionRestored) {
          await windowManager.center();
        }
      }
      await windowManager.show();
      if (isMax) {
        await windowManager.maximize();
      }
      await windowManager.focus();
    });
  }
}
