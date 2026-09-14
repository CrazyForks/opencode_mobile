import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';
import '../app_logger.dart';
import '../../api/opencode_client.dart';
import '../../controllers/pty_controller.dart';
import '../../controllers/session_controller.dart';
import '../../init.dart';
import '../../api/sidecar_manager.dart';

/// Controls the application window's title bar interactions: minimize,
/// maximize/restore, always-on-top, and drag state. Also handles graceful
/// shutdown on window close to prevent orphaned child processes.
class TitleBarController extends GetxController with WindowListener {
  /// Whether the window is currently maximized.
  bool isMax = Global.settings.isMax;

  /// Whether the window is set to stay on top of other windows.
  bool onTop = Global.settings.onTop;
  bool _restoringSize = false; // 标记正在恢复尺寸，跳过 onWindowResized 保存
  bool _sidecarStopped = false; // 保证 stop 只执行一次
  bool _closing = false; // 关闭流程重入守卫：setPreventClose(false) 后
  // 的 close() 会再次触发 onWindowClose，必须直接放行走原生销毁。

  @override
  void onInit() {
    windowManager.addListener(this);
    super.onInit();
  }

  @override
  void onClose() {
    windowManager.removeListener(this);
    super.onClose();
  }

  /// Minimizes the application window.
  Future<void> pressMini() async {
    await windowManager.minimize();
  }

  /// Toggles the "always on top" state of the window and persists the setting.
  Future<void> pressTop() async {
    bool isOnTop = await windowManager.isAlwaysOnTop();
    if (isOnTop) {
      await windowManager.setAlwaysOnTop(false);
      await Global.settings.setOnTop(false);
      onTop = false;
    } else {
      await windowManager.setAlwaysOnTop(true);
      await Global.settings.setOnTop(true);
      onTop = true;
    }
    update();
  }

  /// Maximizes the window. Saves the current window size before maximizing so
  /// it can be restored later.
  Future<void> pressMax() async {
    if (!isMax) {
      final size = await windowManager.getSize();
      await Global.settings.setWindowSize([
        size.width.toString(),
        size.height.toString(),
      ]);
    }
    await windowManager.maximize();
    isMax = true;
    await Global.settings.setIsMax(true);
    update();
  }

  /// Restores the window from maximized to normal state.
  Future<void> pressUnMax() async {
    _restoringSize = true;
    await windowManager.unmaximize();
    isMax = false;
    await Global.settings.setIsMax(false);
    update();
    Future.delayed(const Duration(milliseconds: 200), () {
      _restoringSize = false;
    });
  }

  /// Intercepts window close to cleanup sidecar / connections.
  ///
  /// 关闭路径说明（实测结论）：
  /// - 不要调 `destroy()`（= PostQuitMessage）：窗口在引擎半析构后才
  ///   DestroyWindow，顶层消息走进已释放的引擎状态必现 APPCRASH
  ///   （flutter_windows.dll 空指针读，WER 写 dump 数秒表现为"无响应"）。
  /// - 正确顺序：本地释放长连接 → 取消关闭拦截 → `close()` 走原生
  ///   WM_CLOSE → DestroyWindow 有序销毁（引擎尚存活）。
  @override
  void onWindowClose() async {
    // setPreventClose(false) 后的 close() 会再次派发本事件，重入必须放行。
    if (_closing) return;
    _closing = true;
    if (!_sidecarStopped) {
      _sidecarStopped = true;
      try {
        if (Get.isRegistered<SessionController>()) {
          Get.find<SessionController>().disconnectSse();
        }
      } catch (e) {
        AppLogger.w('onWindowClose disconnect SSE failed: $e');
      }
      try {
        if (Get.isRegistered<PtyController>()) {
          for (final s in Get.find<PtyController>().sessions.toList()) {
            try {
              s.dispose();
            } catch (_) {}
          }
        }
      } catch (e) {
        AppLogger.w('onWindowClose dispose PTY failed: $e');
      }
      // Dio 连接池强制 RST：SSE 流 + keep-alive 连接若走优雅关闭，
      // teardown 会等服务端 FIN（实测约 5s）。必须在 stop/close 之前。
      try {
        OpenCodeClient().closeForShutdown();
        SidecarManager.instance.closeForShutdown();
      } catch (e) {
        AppLogger.w('onWindowClose abort sockets failed: $e');
      }
      try {
        await SidecarManager.instance.stop();
      } catch (e) {
        AppLogger.e('WindowController onWindowClose stop sidecar error', e);
      }
    }
    // 取消拦截后走原生有序销毁；失败才回退到 destroy()。
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (e) {
      AppLogger.e('onWindowClose native close failed, destroying', e);
      try {
        await windowManager.destroy();
      } catch (e2) {
        AppLogger.e('onWindowClose destroy failed', e2);
      }
    }
    super.onWindowClose();
  }

  @override
  void onWindowMaximize() {
    if (!isMax) {
      isMax = true;
      Global.settings.setIsMax(true);
      update();
    }
    super.onWindowMaximize();
  }

  @override
  void onWindowUnmaximize() {
    if (isMax) {
      isMax = false;
      Global.settings.setIsMax(false);
      update();
    }
    super.onWindowUnmaximize();
  }

  @override
  void onWindowResized() async {
    final isMaximized = await windowManager.isMaximized();
    final isMinimized = await windowManager.isMinimized();
    if (isMaximized || isMinimized || _restoringSize) {
      super.onWindowResized();
      return;
    }
    Size size = await windowManager.getSize();
    await Global.settings.setWindowSize([
      size.width.toString(),
      size.height.toString(),
    ]);
    super.onWindowResized();
  }

  @override
  void onWindowMoved() async {
    final isMaximized = await windowManager.isMaximized();
    final isMinimized = await windowManager.isMinimized();
    if (isMaximized || isMinimized) {
      super.onWindowMoved();
      return;
    }
    Offset windowPosition = await windowManager.getPosition();
    await Global.settings.setWindowPosition([
      windowPosition.dx.toString(),
      windowPosition.dy.toString(),
    ]);
    super.onWindowMoved();
  }
}
