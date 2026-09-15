import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';
import '../../controllers/project_controller.dart';
import '../../controllers/tablet_tool_controller.dart';
import '../../init.dart';
import '../../utils/layout_utils.dart';
import 'window_button.dart';
import 'window_controller.dart';

/// Top-level independent title bar for desktop platforms (Windows / macOS / Linux).
/// Spans across the entire window width, separate from any page-level AppBars.
class DesktopTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const DesktopTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    // TitleBarController 由 GlobalBinding 常驻注册，这里只取不用兜底创建，
    // 时序异常时直接抛错而不是静默双注册。
    final controller = Get.find<TitleBarController>();
    final projectCtrl = Get.isRegistered<ProjectController>()
        ? Get.find<ProjectController>()
        : null;

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        // 最大化状态下必须先真实还原再拖拽：window_manager 的
        // startDragging 原生实现是 SendMessage(WM_SYSCOMMAND, SC_MOVE)，
        // 而 Win32 在窗口最大化时会忽略 SC_MOVE —— 窗口既不移动也不还原，
        // 只会留下"手势已结束但窗口仍最大化"的状态错位。
        // 行为与 Chrome / VS Code 标题栏一致；isMax 的同步交由
        // onWindowMaximize / onWindowUnmaximize 回调按窗口真实状态完成。
        onPanStart: (details) async {
          if (await windowManager.isMaximized()) {
            await controller.pressUnMax();
          }
          await windowManager.startDragging();
        },
        onDoubleTap: () async {
          if (controller.isMax) {
            await controller.pressUnMax();
          } else {
            await controller.pressMax();
          }
        },
        child: Container(
          height: Global.titleBarHeight,
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            children: [
              if (projectCtrl != null)
                Obx(() {
                  final proj = projectCtrl.activeProject.value;
                  final title = (proj?.displayName.isNotEmpty == true)
                      ? proj!.displayName
                      : 'OpenCode';
                  return Text(
                    title,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                      color: theme.textTheme.bodyMedium?.color?.withValues(
                        alpha: 0.85,
                      ),
                    ),
                  );
                })
              else
                Text(
                  'OpenCode',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                    color: theme.textTheme.bodyMedium?.color?.withValues(
                      alpha: 0.85,
                    ),
                  ),
                ),
              // Draggable middle area
              const Spacer(),
              // Panel layout toggle button (right panel). Hidden on splash screen:
              // the panel hosts terminal/browser/review tabs on desktop Home,
              // but should not be shown while connecting or on the splash screen.
              if (Get.isRegistered<TabletToolController>())
                Obx(() {
                  if (!controller.showToolPanelToggle) {
                    return const SizedBox.shrink();
                  }
                  final toolCtrl = Get.find<TabletToolController>();
                  final isVisible = toolCtrl.isVisible.value;
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: () => toolCtrl.togglePanel(),
                        iconSize: 15,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        icon: Icon(
                          CupertinoIcons.sidebar_right,
                          color: isVisible
                              ? theme.colorScheme.primary
                              : theme.textTheme.bodyMedium?.color?.withValues(
                                  alpha: 0.7,
                                ),
                        ),
                      ),
                      const SizedBox(width: 2),
                    ],
                  );
                }),
              // Window buttons on the far right
              WindowsButtons(controller: controller),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Size get preferredSize => Size.fromHeight(Global.titleBarHeight);
}
