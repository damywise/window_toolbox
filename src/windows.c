// GPU-recovery detection module for Windows.
//
// Ported from https://github.com/DitriXNew/windows_gpu_recovery (MIT).
// Compiled as a native asset by hook/build.dart and linked into the
// embedding executable; the host calls GpuRecoveryInstall() and receives
// a posted message on a window of its choosing when the GPU is lost.
// Recovery itself (engine recreation) is the host's responsibility.

// The runner target compiles this file at /W4 /WX; the D3D/DXGI SDK headers
// trigger C4201 (nameless struct/union) in C mode, so silence it just for the
// include block.
#pragma warning(push)
#pragma warning(disable : 4201)
#include <windows.h>

#include <d3d11.h>
#include <dxgi.h>
#include <psapi.h>
#pragma warning(pop)

#include <stdio.h>
#include <string.h>

// The ninja build links a bare DLL — pull in the Win32 import libs here
// instead of adding link-line dependencies.
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "psapi.lib")
#pragma comment(lib, "dxguid.lib")

#define GPU_RECOVERY_EXPORT __declspec(dllexport)

#define GPU_LOG(msg)                    \
  do {                                  \
    fprintf(stderr, "[gpu-recovery] " msg "\n"); \
    fflush(stderr);                     \
    wchar_t _dbg_[512];                 \
    _snwprintf_s(_dbg_, 512, _TRUNCATE, L"[gpu-recovery] " L##msg L"\n"); \
    OutputDebugStringW(_dbg_);          \
  } while (0)

#define GPU_LOGF(fmt, ...)                                   \
  do {                                                       \
    fprintf(stderr, "[gpu-recovery] " fmt "\n", __VA_ARGS__); \
    fflush(stderr);                                          \
    wchar_t _dbg_[512];                                      \
    _snwprintf_s(_dbg_, 512, _TRUNCATE, L"[gpu-recovery] " L##fmt L"\n", \
                 __VA_ARGS__);                               \
    OutputDebugStringW(_dbg_);                               \
  } while (0)

// ---------------------------------------------------------------------------
// Vectored Exception Handler
// ---------------------------------------------------------------------------
// Catches ACCESS_VIOLATION inside flutter_windows.dll during engine
// destruction (ANGLE tries to Release dead D3D COM objects). Instead of
// crashing, we skip the faulting instruction so eglTerminate can finish
// and clear the per-process EGLDisplay singleton.

static DWORD64 g_flutter_dll_base = 0;
static DWORD64 g_flutter_dll_end = 0;
// Exception-continuation scope. Detection only queues recovery; the host opens
// this window immediately before it destroys the engine and closes it as soon
// as destruction returns. Atomic because teardown faults arrive on
// engine-owned threads, not necessarily the platform thread.
static volatile LONG g_teardown_active = 0;
static volatile LONG g_exceptions_caught = 0;
static int g_veh_registered = 0;

// ---------------------------------------------------------------------------
// Diagnostics: identify the module owning an AV that lands OUTSIDE
// flutter_windows.dll (straggler worker threads racing engine teardown).
// Resolved dynamically to match the file's no-extra-import-lib style.
// ---------------------------------------------------------------------------

typedef USHORT(WINAPI* CaptureStackBackTraceFn)(DWORD FramesToSkip,
                                                DWORD FramesToCapture,
                                                PVOID* BackTrace,
                                                PDWORD BackTraceHash);

static CaptureStackBackTraceFn GetStackBackTraceFn(void) {
  static CaptureStackBackTraceFn fn = NULL;
  static int resolved = 0;
  if (!resolved) {
    resolved = 1;
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    if (ntdll)
      fn = (CaptureStackBackTraceFn)GetProcAddress(
          ntdll, "RtlCaptureStackBackTrace");
  }
  return fn;
}

// Log "<tag> module.dll+0xOFFSET" for an address.
static void LogAddressModule(const wchar_t* tag, DWORD64 addr) {
  HMODULE mod = NULL;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                              GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          (LPCWSTR)(ULONG_PTR)addr, &mod) ||
      mod == NULL) {
    GPU_LOGF("%ls 0x%llx (unresolved)", tag, (unsigned long long)addr);
    return;
  }
  DWORD64 base = (DWORD64)(ULONG_PTR)mod;
  MODULEINFO mi;
  if (GetModuleInformation(GetCurrentProcess(), mod, &mi, sizeof(mi)))
    base = (DWORD64)(ULONG_PTR)mi.lpBaseOfDll;
  wchar_t path[MAX_PATH];
  const wchar_t* name = L"?";
  if (GetModuleFileNameW(mod, path, MAX_PATH) != 0) {
    const wchar_t* slash = wcsrchr(path, L'\\');
    name = slash ? slash + 1 : path;
  }
  GPU_LOGF("%ls %ls+0x%llx", tag, name,
           (unsigned long long)(addr - base));
}

static LONG CALLBACK GpuRecoveryExceptionHandler(PEXCEPTION_POINTERS info) {
  if (InterlockedCompareExchange(&g_teardown_active, 0, 0) == 0)
    return EXCEPTION_CONTINUE_SEARCH;
  if (info->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION)
    return EXCEPTION_CONTINUE_SEARCH;

  DWORD64 rip = info->ContextRecord->Rip;

  // Only handle crashes inside flutter_windows.dll. An AV anywhere else is
  // a straggler thread in another module — log the faulting RIP and the
  // crashing thread's stack so the owning subsystem can be identified, then
  // still let WER produce its record.
  if (rip < g_flutter_dll_base || rip >= g_flutter_dll_end) {
    LogAddressModule(L"AV outside flutter_windows.dll at", rip);
    CaptureStackBackTraceFn capture = GetStackBackTraceFn();
    if (capture) {
      PVOID frames[24];
      DWORD hash = 0;
      USHORT captured = capture(0, 24, frames, &hash);
      USHORT i;
      for (i = 0; i < captured; i++) {
        wchar_t tag[32];
        _snwprintf_s(tag, _countof(tag), _TRUNCATE, L"AV stack #%u:",
                     (unsigned int)i);
        LogAddressModule(tag, (DWORD64)(ULONG_PTR)frames[i]);
      }
    }
    return EXCEPTION_CONTINUE_SEARCH;
  }

  LONG const caught = InterlockedIncrement(&g_exceptions_caught);
  if (caught <= 5 || caught % 100 == 0) {
    GPU_LOGF("Caught AV #%ld at RIP=flutter_windows.dll+0x%llx", caught,
             (unsigned long long)(rip - g_flutter_dll_base));
  }

  // --- Decode x64 instruction length to skip past it ---
  BYTE* p = (BYTE*)rip;
  int pos = 0;

  // 1. Legacy prefixes
  while (p[pos] == 0x66 || p[pos] == 0x67 || p[pos] == 0xF2 ||
         p[pos] == 0xF3 || p[pos] == 0x2E || p[pos] == 0x3E ||
         p[pos] == 0x26 || p[pos] == 0x36 || p[pos] == 0x64 ||
         p[pos] == 0x65 || p[pos] == 0xF0)
    pos++;

  // 2. REX prefix (0x40-0x4F)
  if (p[pos] >= 0x40 && p[pos] <= 0x4F) pos++;

  // 3. Opcode
  BYTE opcode = p[pos++];
  int has_modrm = 0;
  int imm_size = 0;

  if (opcode == 0x0F) {
    // Two-byte opcode
    opcode = p[pos++];
    has_modrm = 1;
  } else {
    if ((opcode & 0xC0) == 0x00 && (opcode & 0x07) < 6) has_modrm = 1;
    if (opcode >= 0x80 && opcode <= 0x8F) has_modrm = 1;
    if (opcode >= 0x88 && opcode <= 0x8F) has_modrm = 1;
    if (opcode >= 0xD8 && opcode <= 0xDF) has_modrm = 1;
    if (opcode == 0x63 || opcode == 0x69 || opcode == 0x6B) has_modrm = 1;
    if (opcode == 0xC0 || opcode == 0xC1) has_modrm = 1;
    if (opcode == 0xC6 || opcode == 0xC7) has_modrm = 1;
    if (opcode == 0xD0 || opcode == 0xD1 || opcode == 0xD2 ||
        opcode == 0xD3)
      has_modrm = 1;
    if (opcode == 0xF6 || opcode == 0xF7) has_modrm = 1;
    if (opcode == 0xFE || opcode == 0xFF) has_modrm = 1;

    if (opcode == 0x80 || opcode == 0x82 || opcode == 0x83 ||
        opcode == 0xC0 || opcode == 0xC1 || opcode == 0x6B ||
        opcode == 0xC6)
      imm_size = 1;
    if (opcode == 0x81 || opcode == 0x69 || opcode == 0xC7) imm_size = 4;
  }

  // 4. ModRM + SIB + displacement
  if (has_modrm) {
    BYTE modrm = p[pos++];
    BYTE mod = modrm >> 6;
    BYTE rm = modrm & 0x07;

    int has_sib = (mod != 3 && rm == 4);
    if (has_sib) {
      BYTE sib = p[pos++];
      if (mod == 0 && (sib & 0x07) == 5) pos += 4;
    }

    if (mod == 0 && rm == 5) pos += 4;
    else if (mod == 1) pos += 1;
    else if (mod == 2) pos += 4;
  }

  // 5. Immediate
  pos += imm_size;
  if (pos < 1) pos = 1;
  if (pos > 15) pos = 15;

  // Advance past the crashing instruction.
  info->ContextRecord->Rip = rip + pos;
  info->ContextRecord->Rax = 0;
  info->ContextRecord->Rdx = 0;
  info->ContextRecord->EFlags |= 0x40;  // ZF=1 (treat dead ptrs as null)

  return EXCEPTION_CONTINUE_EXECUTION;
}

// ---------------------------------------------------------------------------
// Dynamic DXGI / D3D11 loading (no import-lib dependencies)
// ---------------------------------------------------------------------------

static HMODULE g_dxgi_dll = NULL;
static HMODULE g_d3d11_dll = NULL;

typedef HRESULT(WINAPI* CreateDXGIFactory1Fn)(REFIID riid, void** ppFactory);
typedef HRESULT(WINAPI* D3D11CreateDeviceFn)(
    IDXGIAdapter* pAdapter, D3D_DRIVER_TYPE DriverType, HMODULE Software,
    UINT Flags, const D3D_FEATURE_LEVEL* pFeatureLevels, UINT FeatureLevels,
    UINT SDKVersion, ID3D11Device** ppDevice,
    D3D_FEATURE_LEVEL* pFeatureLevel, ID3D11DeviceContext** ppImmediateContext);

static CreateDXGIFactory1Fn GetCreateDXGIFactory1(void) {
  if (!g_dxgi_dll) {
    g_dxgi_dll = LoadLibraryW(L"dxgi.dll");
    if (!g_dxgi_dll) {
      GPU_LOG("LoadLibrary(dxgi.dll) failed");
      return NULL;
    }
  }
  return (CreateDXGIFactory1Fn)GetProcAddress(g_dxgi_dll,
                                            "CreateDXGIFactory1");
}

static D3D11CreateDeviceFn GetD3D11CreateDevice(void) {
  if (!g_d3d11_dll) {
    g_d3d11_dll = LoadLibraryW(L"d3d11.dll");
    if (!g_d3d11_dll) {
      GPU_LOG("LoadLibrary(d3d11.dll) failed");
      return NULL;
    }
  }
  return (D3D11CreateDeviceFn)GetProcAddress(g_d3d11_dll, "D3D11CreateDevice");
}

// ---------------------------------------------------------------------------
// Sentinel device + watchdog message-only window
// ---------------------------------------------------------------------------
// The module owns a message-only window so the watchdog survives app-window
// churn. The timer polls the sentinel D3D11 device; on device loss it posts
// `recovery_msg` to the host-provided `target_hwnd` — detection does not arm
// exception continuation; the host opens that window around engine teardown
// via GpuRecoveryBeginTeardown().

GPU_RECOVERY_EXPORT BOOL GpuRecoveryIsDeviceLost(void);

static const wchar_t* kHostClassName = L"WindowToolboxGpuRecoveryHost";
static const UINT_PTR kGpuWatchdogTimerId = 1;
static const UINT kWatchdogIntervalMs = 2000;

static HWND g_host_hwnd = NULL;
static HWND g_target_hwnd = NULL;
static UINT g_recovery_msg = 0;
static int g_class_registered = 0;

static IDXGIAdapter* g_adapter = NULL;
static ID3D11Device* g_sentinel_device = NULL;
static int g_recovery_requested = 0;

// LUID of the last adapter passed to GpuRecoverySetAdapter, so
// GpuRecoveryWaitForGpuReady can verify Flutter's adapter instead of
// assuming it sits at DXGI index 0.
static LUID g_adapter_luid;
static BOOL g_has_adapter_luid = FALSE;

// Returns whether the 2 s timer is actually live — callers propagate this
// so a NULL window or failed SetTimer is never reported as armed.
static BOOL ArmWatchdog(void) {
  g_recovery_requested = 0;
  if (!g_host_hwnd) {
    GPU_LOG("Watchdog not armed — no host window");
    return FALSE;
  }
  if (!SetTimer(g_host_hwnd, kGpuWatchdogTimerId, kWatchdogIntervalMs, NULL)) {
    GPU_LOGF("Watchdog SetTimer failed (%lu)", GetLastError());
    return FALSE;
  }
  GPU_LOG("Watchdog (re)armed (2 s interval)");
  return TRUE;
}

static LRESULT CALLBACK GpuRecoveryWndProc(HWND hwnd, UINT message,
                                           WPARAM wparam, LPARAM lparam) {
  if (message == WM_TIMER && wparam == kGpuWatchdogTimerId) {
    if (GpuRecoveryIsDeviceLost() && !g_recovery_requested) {
      GPU_LOG("Device loss detected — queuing recovery (continuation NOT armed)");
      g_recovery_requested = 1;
      KillTimer(hwnd, kGpuWatchdogTimerId);

      // Tell the host window to recreate the engine. A failed post with
      // the timer killed would leave no recovery queued, so restore the
      // retryable state and let the next tick re-post.
      GPU_LOG("Posting recovery message");
      if (g_target_hwnd == NULL ||
          !PostMessage(g_target_hwnd, g_recovery_msg, 0, 0)) {
        if (g_target_hwnd) {
          GPU_LOGF("Recovery PostMessage failed (%lu)", GetLastError());
        } else {
          GPU_LOG("Recovery PostMessage failed — no target window");
        }
        g_recovery_requested = 0;
        ArmWatchdog();
      }
    }
    return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

GPU_RECOVERY_EXPORT BOOL GpuRecoveryInstall(HWND target_hwnd,
                                            UINT recovery_msg) {
  BOOL ok = TRUE;

  // Resolve the flutter_windows.dll image range and register the VEH.
  // Both are retried on every call while unresolved — the DLL may load
  // after the first Install, and a failed registration must not wedge the
  // watchdog. AddVectoredExceptionHandler runs at most once (on success);
  // the handler stays inert until the host opens the teardown window with
  // GpuRecoveryBeginTeardown().
  if (g_flutter_dll_base == 0) {
    HMODULE hmod = GetModuleHandleA("flutter_windows.dll");
    if (hmod) {
      MODULEINFO mi;
      if (GetModuleInformation(GetCurrentProcess(), hmod, &mi, sizeof(mi))) {
        g_flutter_dll_base = (DWORD64)mi.lpBaseOfDll;
        g_flutter_dll_end = g_flutter_dll_base + mi.SizeOfImage;
        GPU_LOGF("flutter_windows.dll: 0x%llx — 0x%llx (%u bytes)",
                 (unsigned long long)g_flutter_dll_base,
                 (unsigned long long)g_flutter_dll_end,
                 (unsigned int)mi.SizeOfImage);
      } else {
        GPU_LOGF("GetModuleInformation(flutter_windows.dll) failed (%lu)",
                 GetLastError());
        ok = FALSE;
      }
    } else {
      GPU_LOG("flutter_windows.dll not loaded yet — VEH will be inert");
      ok = FALSE;
    }
  }
  if (!g_veh_registered) {
    if (AddVectoredExceptionHandler(1, GpuRecoveryExceptionHandler)) {
      g_veh_registered = 1;
    } else {
      GPU_LOGF("AddVectoredExceptionHandler failed (%lu)", GetLastError());
      ok = FALSE;
    }
  }

  g_target_hwnd = target_hwnd;
  g_recovery_msg = recovery_msg;

  // Create the module-owned message-only host window (once). A failed
  // register or create leaves g_host_hwnd NULL so the next call retries.
  if (!g_host_hwnd) {
    HINSTANCE hinstance = GetModuleHandleW(NULL);
    if (!g_class_registered) {
      WNDCLASSW wc;
      memset(&wc, 0, sizeof(wc));
      wc.lpfnWndProc = GpuRecoveryWndProc;
      wc.hInstance = hinstance;
      wc.lpszClassName = kHostClassName;
      if (RegisterClassW(&wc) ||
          GetLastError() == ERROR_CLASS_ALREADY_EXISTS) {
        g_class_registered = 1;
      } else {
        GPU_LOGF("RegisterClass failed (%lu)", GetLastError());
        ok = FALSE;
      }
    }
    if (g_class_registered) {
      g_host_hwnd = CreateWindowExW(0, kHostClassName, L"", 0, 0, 0, 0, 0,
                                    HWND_MESSAGE, NULL, hinstance, NULL);
      if (!g_host_hwnd) {
        GPU_LOGF("Message window creation failed (%lu)", GetLastError());
        ok = FALSE;
      } else {
        GPU_LOG("Message-only watchdog window created");
      }
    }
  }

  if (!ArmWatchdog())
    ok = FALSE;
  return ok;
}

// Ownership: the module takes ownership of the passed IDXGIAdapter* on ALL
// paths, including failures — it is released on the next
// GpuRecoverySetAdapter call and in GpuRecoveryShutdown(). Returns TRUE only
// when a sentinel device was created and the watchdog timer is live.
GPU_RECOVERY_EXPORT BOOL GpuRecoverySetAdapter(void* adapter) {
  // Release the previous sentinel device and adapter.
  if (g_sentinel_device) {
    g_sentinel_device->lpVtbl->Release(g_sentinel_device);
    g_sentinel_device = NULL;
  }
  if (g_adapter) {
    g_adapter->lpVtbl->Release(g_adapter);
    g_adapter = NULL;
  }
  g_has_adapter_luid = FALSE;

  g_adapter = (IDXGIAdapter*)adapter;
  if (!g_adapter) {
    GPU_LOG("SetAdapter(NULL) — sentinel disabled");
    return FALSE;
  }

  // Remember the adapter LUID so WaitForGpuReady can re-find this exact
  // adapter rather than assuming DXGI index 0.
  {
    DXGI_ADAPTER_DESC adapter_desc;
    HRESULT desc_hr = g_adapter->lpVtbl->GetDesc(g_adapter, &adapter_desc);
    if (SUCCEEDED(desc_hr)) {
      g_adapter_luid = adapter_desc.AdapterLuid;
      g_has_adapter_luid = TRUE;
    } else {
      GPU_LOGF("Adapter GetDesc failed (0x%lx) — LUID unknown", desc_hr);
    }
  }

  D3D11CreateDeviceFn create_device = GetD3D11CreateDevice();
  if (!create_device) {
    GPU_LOG("D3D11CreateDevice unavailable — sentinel disabled");
    ArmWatchdog();
    return FALSE;
  }

  D3D_FEATURE_LEVEL fl;
  HRESULT hr = create_device(g_adapter, D3D_DRIVER_TYPE_UNKNOWN, NULL, 0,
                             NULL, 0, D3D11_SDK_VERSION, &g_sentinel_device,
                             &fl, NULL);
  if (FAILED(hr)) {
    GPU_LOGF("Sentinel D3D11CreateDevice failed (0x%lx)", hr);
    ArmWatchdog();
    return FALSE;
  }
  GPU_LOG("Sentinel D3D device created");

  // (Re)arm the watchdog against the fresh adapter.
  return ArmWatchdog();
}

GPU_RECOVERY_EXPORT BOOL GpuRecoveryIsDeviceLost(void) {
  if (!g_sentinel_device) return FALSE;
  return g_sentinel_device->lpVtbl->GetDeviceRemovedReason(
             g_sentinel_device) != S_OK;
}

// Opens the exception-continuation window. Call it immediately before
// destroying the engine and close it with GpuRecoveryEndTeardown() as soon
// as destruction returns. Returns TRUE only when a teardown AV inside
// flutter_windows.dll would actually be continued — i.e. the VEH is registered
// and its image range resolved; FALSE means teardown is about to run with no
// continuation and an unexpected AV will crash the process normally.
GPU_RECOVERY_EXPORT BOOL GpuRecoveryBeginTeardown(void) {
  if (!g_veh_registered || g_flutter_dll_base == 0) {
    GPU_LOG("BeginTeardown: continuation unavailable (VEH unregistered or "
            "flutter_windows.dll range unresolved)");
    return FALSE;
  }
  LONG const previous = InterlockedExchange(&g_teardown_active, 1);
  InterlockedExchange(&g_exceptions_caught, 0);
  if (previous != 0)
    GPU_LOG("BeginTeardown: window already open — re-opened");
  GPU_LOG("BeginTeardown: exception-continuation window OPEN");
  return TRUE;
}

// Closes the window and reports how many AVs were continued inside it. Always
// safe to call; the window is disarmed even if it was not open.
GPU_RECOVERY_EXPORT void GpuRecoveryEndTeardown(void) {
  LONG const caught = InterlockedExchange(&g_exceptions_caught, 0);
  LONG const was_active = InterlockedExchange(&g_teardown_active, 0);
  if (was_active)
    GPU_LOGF("EndTeardown: window CLOSED after %ld continued AV(s)", caught);
  else
    GPU_LOG("EndTeardown: window CLOSED (was not open)");
}

GPU_RECOVERY_EXPORT BOOL GpuRecoveryWaitForGpuReady(DWORD timeout_ms) {
  // Poll until a fresh test device on the Flutter adapter is healthy, or
  // timeout. When the adapter LUID is known (recorded by
  // GpuRecoverySetAdapter) enumerate adapters and match on it; otherwise
  // fall back to index 0, which may not be Flutter's GPU — the log says so.
  const DWORD kPollMs = 200;
  const DWORD start = GetTickCount();
  int attempt = 0;

  for (;;) {
    IDXGIFactory1* factory = NULL;
    attempt++;
    Sleep(kPollMs);

    CreateDXGIFactory1Fn create_factory = GetCreateDXGIFactory1();
    D3D11CreateDeviceFn create_device = GetD3D11CreateDevice();
    if (!create_factory || !create_device) {
      GPU_LOG("DXGI/D3D11 unavailable — cannot verify GPU readiness");
      return FALSE;
    }

    if (SUCCEEDED(create_factory(&IID_IDXGIFactory1, (void**)&factory))) {
      UINT index;
      for (index = 0;; index++) {
        IDXGIAdapter1* adapter = NULL;
        BOOL matched = FALSE;
        ID3D11Device* test_device = NULL;
        if (FAILED(factory->lpVtbl->EnumAdapters1(factory, index, &adapter)))
          break;

        if (g_has_adapter_luid) {
          DXGI_ADAPTER_DESC1 desc1;
          if (SUCCEEDED(adapter->lpVtbl->GetDesc1(adapter, &desc1)) &&
              desc1.AdapterLuid.LowPart == g_adapter_luid.LowPart &&
              desc1.AdapterLuid.HighPart == g_adapter_luid.HighPart)
            matched = TRUE;
        } else {
          matched = (index == 0);
        }

        if (matched) {
          D3D_FEATURE_LEVEL level;
          HRESULT hr = create_device((IDXGIAdapter*)adapter,
                                     D3D_DRIVER_TYPE_UNKNOWN, NULL, 0, NULL,
                                     0, D3D11_SDK_VERSION, &test_device,
                                     &level, NULL);
          if (SUCCEEDED(hr) &&
              test_device->lpVtbl->GetDeviceRemovedReason(test_device) ==
                  S_OK) {
            if (g_has_adapter_luid) {
              GPU_LOGF("GPU ready after %u ms",
                       (unsigned int)(GetTickCount() - start));
            } else {
              GPU_LOGF("Adapter 0 verified after %u ms (Flutter adapter "
                       "unknown)",
                       (unsigned int)(GetTickCount() - start));
            }
            test_device->lpVtbl->Release(test_device);
            adapter->lpVtbl->Release(adapter);
            factory->lpVtbl->Release(factory);
            return TRUE;
          }
          if (test_device) test_device->lpVtbl->Release(test_device);
          adapter->lpVtbl->Release(adapter);
          break;  // only the matching adapter is tested
        }
        adapter->lpVtbl->Release(adapter);
      }
      factory->lpVtbl->Release(factory);
    }

    if (GetTickCount() - start >= timeout_ms) {
      GPU_LOGF("GPU not ready after %lu ms — giving up", timeout_ms);
      return FALSE;
    }
  }
}

GPU_RECOVERY_EXPORT void GpuRecoveryShutdown(void) {
  if (g_host_hwnd) {
    KillTimer(g_host_hwnd, kGpuWatchdogTimerId);
    DestroyWindow(g_host_hwnd);
    g_host_hwnd = NULL;
  }
  if (g_sentinel_device) {
    g_sentinel_device->lpVtbl->Release(g_sentinel_device);
    g_sentinel_device = NULL;
  }
  if (g_adapter) {
    g_adapter->lpVtbl->Release(g_adapter);
    g_adapter = NULL;
  }
  g_recovery_requested = 0;
  InterlockedExchange(&g_teardown_active, 0);
  InterlockedExchange(&g_exceptions_caught, 0);
  g_has_adapter_luid = FALSE;
  GPU_LOG("Shutdown");
}
