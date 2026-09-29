# GPU-recovery detection (Windows)

`src/windows.c` is a Windows-only, dependency-free C module that **detects**
D3D11 device loss and notifies a host-provided window. It is compiled by the
native-assets hook (`hook/build.dart`, asset name `windows`) and linked into
the embedding executable — a host may also compile the file directly into its
runner target. **Recovery itself is the host's responsibility**; the module
only detects and signals.

Ported from [DitriXNew/windows_gpu_recovery](https://github.com/DitriXNew/windows_gpu_recovery)
(MIT), adapted for multi-window Flutter apps whose windows/views are created
from Dart (no `FlutterViewController` on the C++ side).

## Why this is hard in Flutter

ANGLE initializes a per-process `EGLDisplay` singleton. After a GPU reset —
TDR, driver disable/enable, sleep/resume, Hyper-V save/restore — that display
is dead and nothing renders until it is destroyed and re-created. The catch:
destroying it faults. `eglTerminate` releases dead D3D COM objects and
access-violates inside `flutter_windows.dll`, so a naive "recreate the
renderer" crashes the process.

The upstream plugin's answer — and ours — is to destroy the whole engine
under a vectored exception handler that skips those faulting AVs, then create
a fresh engine. Recovery is therefore **engine-level and process-global by
design**: the EGLDisplay singleton makes per-window recovery impossible
without engine-source work.

A "restore just the renderer" engine-fork fix (along the lines of
`FlutterWindowsEngine::HandleDeviceLost`: abandon the Skia context → guarded
`eglTerminate` → recreate the EGL manager, per-view surfaces and compositor)
is the proper long-term fix. The detection module here is the reusable half
of that work.

## Architecture

Three cooperating pieces, all in `src/windows.c`:

- **Sentinel device** — a persistent D3D11 device created on the same
  `IDXGIAdapter` the Flutter engine reports via
  `FlutterDesktopEngineGetGraphicsAdapter` (the host passes the adapter to
  `GpuRecoverySetAdapter`, the module takes ownership and releases it on
  replacement/shutdown). The watchdog polls
  `ID3D11Device::GetDeviceRemovedReason() != S_OK` to detect loss.
- **Watchdog** — a module-owned **message-only window** (class
  `WindowToolboxGpuRecoveryHost`, parent `HWND_MESSAGE`) with a 2 s
  `SetTimer`. It is deliberately *not* latched to an app window, because
  tear-off/multi-window apps destroy their top-level HWNDs constantly. On
  loss it arms the VEH flag, kills its own timer, and posts the host-chosen
  message (`target_hwnd` + `recovery_msg` from `GpuRecoveryInstall`). It runs
  on the thread that called `GpuRecoveryInstall` — call it on the platform
  thread.
- **VEH** — `AddVectoredExceptionHandler(1, ...)`. While the recovery flag is
  active it catches `EXCEPTION_ACCESS_VIOLATION` whose RIP is inside
  `flutter_windows.dll` (range resolved via `GetModuleInformation` at Install
  time), decodes the x64 instruction length (legacy prefixes / REX / opcode /
  ModRM / SIB / displacement / immediate, capped at 15 bytes), skips the
  faulting instruction, zeroes `RAX`/`RDX` and sets `ZF`. That lets
  `eglTerminate` finish instead of crashing. AVs **outside**
  `flutter_windows.dll` are logged — faulting RIP resolved to
  `module.dll+0xOFFSET` plus a 24-frame `RtlCaptureStackBackTrace` of the
  crashing thread — then passed through untouched (a straggler MinGW pthread
  UAF still crashes; see pitfalls).

Everything degrades to a loud logged no-op: missing `d3d11.dll`/`dxgi.dll`
(both loaded dynamically via `LoadLibraryW`, so there are no import-lib
dependencies), missing `flutter_windows.dll` at Install time (VEH inert),
sentinel creation failure, etc. All logging uses the `[gpu-recovery]` prefix
to stderr plus `OutputDebugStringW`.

### Message sequence

```
host (platform thread)                    module watchdog (same thread, timer)
        │                                          │
        ├─ GpuRecoveryInstall(host, recovery_msg)  │
        │    └─ AddVectoredExceptionHandler        │
        │    └─ message-only window + SetTimer     │
        ├─ GpuRecoverySetAdapter(engine adapter)   │
        │    └─ sentinel D3D11 device              │
        │                              WM_TIMER (2 s)
        │                                  │ GetDeviceRemovedReason() != S_OK
        │                                  ├─ arm VEH flag, KillTimer
        │                                  └─ PostMessage(host, recovery_msg)
        ├─ recovery_msg handler:                   │
        │    write marker file                     │
        │    stop native worker threads            │
        │    destroy engine  ── AVs in flutter_windows.dll skipped by VEH
        │    GpuRecoveryWaitForGpuReady(10000)     │
        │    create + register + run fresh engine  │
        └─ GpuRecoverySetAdapter(new adapter) ────►│ watchdog re-arms
```

## API reference

All exports are `extern "C"`.

| Function | Purpose |
|---|---|
| `GpuRecoveryInstall(HWND target_hwnd, UINT recovery_msg)` | Registers the VEH (once), creates the message-only watchdog window (once), arms the 2 s timer. Call on the platform thread. |
| `GpuRecoverySetAdapter(void* adapter)` | `IDXGIAdapter*`; module takes ownership. Releases the previous sentinel/adapter, creates a fresh sentinel on the new adapter, re-arms the watchdog. Call after Install **and again after every engine recreation**. |
| `GpuRecoveryIsDeviceLost(void)` | `TRUE` if the sentinel's `GetDeviceRemovedReason() != S_OK`. `FALSE` when no sentinel exists. |
| `GpuRecoveryWaitForGpuReady(DWORD timeout_ms)` | Polls every 200 ms: creates a fresh test device on adapter 0 via `CreateDXGIFactory1` → `EnumAdapters1(0)` → `D3D11CreateDevice` and checks `GetDeviceRemovedReason`. Returns `TRUE` once healthy, `FALSE` on timeout. |
| `GpuRecoveryShutdown(void)` | Kills the timer, destroys the hidden window, releases sentinel and adapter, clears the recovery/VEH flags. |

## Host integration contract

The reference implementation is captionify's `windows/runner/main.cpp`.

1. Create a hidden message-only host window whose WndProc handles the
   recovery message on the platform thread.
2. After the engine runs: `GpuRecoveryInstall(host, msg)` — captionify uses
   `WM_APP + 0x5250` — then query the engine adapter
   (`FlutterEngine::GetGraphicsAdapter` →
   `FlutterDesktopEngineGetGraphicsAdapter`) and `GpuRecoverySetAdapter`.
   **`GetGraphicsAdapter` can fail before the engine has any view** — retry
   on a timer until it succeeds, otherwise the watchdog arms with no
   sentinel and detects nothing.
3. On the recovery message: write a marker file → stop/quiesce any native
   worker threads that touch Flutter (see pitfall 2) → destroy the engine
   (VEH is now active and eats the ANGLE teardown AVs) →
   `GpuRecoveryWaitForGpuReady(10000)` → create + register + run a fresh
   engine → `GpuRecoverySetAdapter` again.
4. The Dart VM restarts as part of engine destruction: any Dart-side
   "main window destroyed → exit the process" handler must be suppressed
   during teardown (e.g. via the marker file) or the process exits
   mid-recovery. Persist whatever app state must survive into the fresh VM
   (see pitfall 1).

## Pitfalls — found the hard way

Each of these was a real crash (or silent failure) during bring-up. Symptom
→ root cause → fix.

1. **Dart-side exit during teardown.**
   *Symptom:* process exits cleanly but instantly the moment recovery starts.
   *Root cause:* the engine's `Stop()` destroys all views; the windowing
   round-trip fires Dart `onWindowDestroyed` while the VM is still alive,
   and an app delegate that calls `exit(0)`/`exitApplication` there kills
   the process mid-recovery.
   *Fix:* discriminate with the marker file — present at destroy time ⇔
   recovery teardown, so the exit handler no-ops.

2. **Native worker threads racing the teardown.**
   *Symptom:* AV during/after `engine.reset()` — outside
   `flutter_windows.dll`, e.g. in `libwinpthread` (captionify: MLT
   GPU-present/audio threads publishing texture frames into destroyed
   registrar state).
   *Root cause:* in-process native stacks with worker threads that touch
   Flutter must be stopped **before** `engine.reset()`.
   *Fix:* an explicit native "shutdown runtime" export called first, gated
   by a **birth-time kill-switch** (a recovery-active flag read when the
   worker spawns) — *not* a monotonically bumped epoch, which permanently
   latches and silently kills runtimes created *after* recovery (this broke
   the post-recovery GPU pipeline once).

3. **`FreeLibrary` under parked threads.**
   *Symptom:* crash when a plugin unloads during teardown.
   *Root cause:* a destructor calls `FreeLibrary` on a DLL that owns worker
   threads sleeping on pthread condvars in its static storage; the thread
   wakes and dereferences the now-unmapped image.
   *Fix:* pin the module at load —
   `GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, ...)`
   — and never `FreeLibrary`.

4. **Silent-arm failure.**
   *Symptom:* detection never works, no errors.
   *Root cause:* arming before the first view exists —
   `GetGraphicsAdapter` needs the engine's rendering context.
   *Fix:* retry `GpuRecoverySetAdapter` on a 2 s host timer until the
   adapter query succeeds.

5. **Debuggers swallow the VEH.**
   *Symptom:* recovery works never / the process just crashes under the IDE.
   *Root cause:* Windows delivers the exception to an attached debugger
   first; the vectored handler never fires.
   *Fix:* test only release builds launched directly, never under a
   debugger.

6. **EGL-error spam is normal.**
   *Symptom:* a stream of `EGL Error: Context Lost (12302)` during
   teardown.
   *Root cause:* ANGLE reporting the dead device — expected noise, not a
   failure.
   *Fix:* none; don't "fix" it.

## Testing

- `dxcap -forcetdr` (run elevated; ships with the *Graphics Tools* optional
  capability → `C:\Windows\System32\dxcap.exe`). Note the FoD-delivered
  version has had `-forcetdr` neutered on some Windows 11 builds — the copy
  from the Visual Studio *Graphics Tools* component is the reliable one,
  and that component exists only in full VS editions, not Build Tools 2022.
- Alternatives: Device Manager disable/enable of the GPU
  (`Get-PnpDevice -Class Display | Disable-PnpDevice`), system
  sleep/resume, Hyper-V save/restore.
- Repeat the TDR **3× in the same process** to check for leak/park
  accumulation. Event Viewer (`Application Error` provider) must stay
  clean. A successful trail ends with the watchdog re-armed on the new
  adapter and the marker consumed at boot.

## Limitations / future work

- Recovery = engine recreation: the Dart VM restarts (in-memory state lost
  unless persisted), ~1–3 s white flash, and one parked runtime per
  recovery is deliberate (bounded leak; freed only at process exit).
- No per-window recovery — the EGLDisplay is process-global. The
  renderer-only engine-fork fix sketched above is the long-term answer and
  this detection module is its reusable half.
- Marker/state files next to the exe are fine for development; move them to
  `%APPDATA%` for installed builds.
