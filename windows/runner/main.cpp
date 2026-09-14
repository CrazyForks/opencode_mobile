#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // --- Single-instance protection ---
  // Skip if --multi-instance is passed (useful for flutter run debugging).
  bool allow_multi = false;
  for (const auto& arg : command_line_arguments) {
    if (arg == "--multi-instance") {
      allow_multi = true;
      break;
    }
  }

  HANDLE mutex = nullptr;
  if (!allow_multi) {
    mutex = ::CreateMutexW(nullptr, FALSE, L"OpenCodeApp_SingleInstance_Mutex");
    if (mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
      // Another instance is already running — try to activate it.
      HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"opencode_app");
      if (existing != nullptr) {
        ::ShowWindow(existing, SW_RESTORE);
        ::SetForegroundWindow(existing);
      }
      // If window not found (race: old instance exiting), don't block — just exit
      // and let the user retry.
      ::CloseHandle(mutex);
      ::CoUninitialize();
      return EXIT_SUCCESS;
    }
    // mutex handle kept open — auto-released by kernel on process exit / crash.
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"opencode_app", origin, size)) {
    if (mutex) ::CloseHandle(mutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
