#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdint>
#include <exception>
#include <new>
#include <stdlib.h>
#include <variant>

#include "flutter_window.h"
#include "utils.h"

// ---- Crash stack logger (pure Win32, no CRT calls inside handlers) ----
// wsprintf lacks %I/%ll; hand-rolled hex conversion
static void HexStr(uintptr_t v, char* out) {  // out[20]
  const char* d = "0123456789ABCDEF";
  char tmp[16];
  int n = 0;
  if (v == 0) {
    out[0] = '0';
    out[1] = '\0';
    return;
  }
  while (v != 0 && n < 16) {
    tmp[n++] = d[v & 0xF];
    v >>= 4;
  }
  for (int i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
  out[n] = '\0';
}

static void WriteCrashLog(const char* tag) {
  wchar_t tmp[MAX_PATH];
  if (!::GetTempPathW(MAX_PATH, tmp)) return;
  wchar_t path[MAX_PATH];
  ::wsprintfW(path, L"%snr_crash_stack.txt", tmp);
  HANDLE h = ::CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return;
  ::SetFilePointer(h, 0, nullptr, FILE_END);
  char line[512];
  int n = ::wsprintfA(line, "==== %s ====\r\n", tag);
  DWORD w;
  ::WriteFile(h, line, (DWORD)n, &w, nullptr);
  void* frames[64];
  USHORT cnt = ::CaptureStackBackTrace(0, 64, frames, nullptr);
  for (USHORT i = 0; i < cnt; i++) {
    HMODULE mod = nullptr;
    char modname[128] = "?";
    if (::GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                 GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                             reinterpret_cast<LPCSTR>(frames[i]), &mod) &&
        mod) {
      char full[260];
      DWORD len = ::GetModuleFileNameA(mod, full, sizeof(full));
      const char* base = full;
      for (DWORD k = 0; k < len; k++)
        if (full[k] == '\\' || full[k] == '/') base = full + k + 1;
      ::lstrcpynA(modname, base, sizeof(modname));
      char off[20];
      HexStr(reinterpret_cast<uintptr_t>(frames[i]) -
                 reinterpret_cast<uintptr_t>(mod),
             off);
      n = ::wsprintfA(line, "  #%02d %s+0x%s\r\n", i, modname, off);
    } else {
      n = ::wsprintfA(line, "  #%02d %p\r\n", i, frames[i]);
    }
    ::WriteFile(h, line, (DWORD)n, &w, nullptr);
  }
  ::CloseHandle(h);
}

static void __cdecl OnInvalidParam(const wchar_t*, const wchar_t*,
                                   const wchar_t*, unsigned int, uintptr_t) {
  WriteCrashLog("CRT_INVALID_PARAMETER");
  ::TerminateProcess(::GetCurrentProcess(), 0x51D1);
}

static void OnTerminate() {
  const char* tag = "CPP_TERMINATE";
  try {
    throw;
  } catch (const std::bad_variant_access&) {
    tag = "CPP_TERMINATE bad_variant_access";
  } catch (const std::bad_alloc&) {
    tag = "CPP_TERMINATE bad_alloc";
  } catch (...) {
  }
  WriteCrashLog(tag);
  ::TerminateProcess(::GetCurrentProcess(), 0x51D2);
}

static LONG WINAPI OnSeh(EXCEPTION_POINTERS* info) {
  char tag[64];
  unsigned int code =
      (info && info->ExceptionRecord) ? info->ExceptionRecord->ExceptionCode : 0;
  ::wsprintfA(tag, "SEH code=0x%08X", code);
  WriteCrashLog(tag);
  return EXCEPTION_EXECUTE_HANDLER;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  _set_invalid_parameter_handler(&OnInvalidParam);
  std::set_terminate(&OnTerminate);
  ::SetUnhandledExceptionFilter(&OnSeh);

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

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"\u723D\u9605", origin, size)) {
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
