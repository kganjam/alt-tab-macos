# AltTab (kganjam fork) — Architecture & Subsystem Map

Bootstrap doc for agents/devs working on **this fork**. It orients you to the
codebase, the subsystems we have heavily customized, and where the deeper docs
live. Read this first, then `AGENTS.md` (workflow rules), then the per-subsystem
docs linked below.

> This is a customized fork of [lwouis/alt-tab-macos](https://github.com/lwouis/alt-tab-macos).
> All of our work lives on branch `parallels-coherence-focus-fix` (the working
> mainline) and is mirrored to `master` on the fork. See **[UPSTREAM.md](UPSTREAM.md)**
> for how to pull changes from the original project.

## What this fork focuses on

Beyond stock AltTab, this fork invests heavily in:
1. **Per-window focus correctness** across Mac↔Mac, Parallels Coherence↔Mac, and
   Par↔Par transitions (never raise all of an app's windows — see the hard gate
   in `AGENTS.md` "Per-window focus behavior").
2. **Z-order stability / recency** (MRU order survives restarts, Coherence
   handoffs, lifecycle churn).
3. **Background thumbnail capture** that stays within macOS's per-client
   IOSurface budget (the subsystem that caused — and now guards against — a
   WindowServer crash; see below).

## Bundle architecture (shim + dylib)

The installed app is a tiny C shim that `dlopen`s the real Swift app as a dylib,
so dev iteration never breaks the code-signing seal / TCC grants. Full details
and the **TCC seal rules** are in `AGENTS.md` → "Bundle architecture" and
"Code signing & TCC". Entry point: `src/main.swift` (`@_cdecl("alt_tab_main")`).

## Source map (where things live)

| Subsystem | Key files | Notes |
| --- | --- | --- |
| App lifecycle / panel | `src/ui/App.swift`, `src/main.swift` | show/hide, focus commit, the in-panel thumbnail timer, profiler launch |
| Window / app model | `src/logic/Window.swift`, `src/logic/Windows.swift`, `src/logic/Application.swift`, `src/logic/Applications.swift` | `Windows.list` is the source of truth, **mutated on the main thread only**; `Applications.removeZombieWindows()` is the GC for windows that closed without an AX event |
| Focus / z-order / recency | `src/logic/Windows.swift` (`sortByLevel`, z-order enforcement, `updateLastFocusOrder`, persisted MRU), `Window.focus()` | Never replace `Window.focus()`'s SLPS→makeKey→AX sequence with app-level activate |
| Parallels Coherence | `src/logic/Window.swift` (Parallels focus + `scheduleFrontmostRepoke`), `src/ui/App.swift` (`scheduleParHideUi`) | Coherence wraps the guest app as one shim wid; SLPS semantics differ |
| **Thumbnail capture + IOSurface budget** | `src/logic/events/WindowCaptureEvents.swift`, `src/logic/ThumbnailCache.swift`, `src/logic/BackgroundThumbnailRefresher.swift`, `src/ui/generic-components/LightImageLayer.swift` | See dedicated section below |
| Events / observers | `src/logic/events/*.swift` (`AccessibilityEvents`, `ScreensEvents`, `SpacesEvents`, `RunningApplicationsEvents`, `SleepWakeEvents`) | AX/window/app/display/space notifications |
| Diagnostics / logging | `src/api-wrappers/Logger.swift` (`Diagnostics`) | level-gated categories; logs to `/tmp/alttab/latest.log` & `/tmp/alttab-run.log` |
| Preferences / runtime flags | `src/logic/Preferences.swift` (`Preferences`, `enum RuntimeFlags`) | **Every flag must agree between the `defaultValues` dict (registered into UserDefaults) and its `RuntimeFlags` accessor default** — a mismatch silently lets the dict win |
| Private SkyLight APIs | `src/api-wrappers/private-apis/SkyLight.framework.swift` | `CGSHWCaptureWindowList` (HW window capture), SLPS, connection id |

## Thumbnail capture & the IOSurface budget (read before touching capture)

AltTab screenshots each window for the gallery via two paths:
- **ScreenCaptureKit** (`SCScreenshotManager.captureSampleBuffer`) for native windows.
- **Private `CGSHWCaptureWindowList`** for Parallels Coherence windows and as the
  SCK fallback (it can capture minimized windows; SCK cannot).

Both return **IOSurface-backed** images. WindowServer keeps a **per-client
IOSurface tally** and calls `abort()` (`WSIOSurfaceDebugTallyAndAbort`, crashing
the whole graphics session) if a client holds too many. A background refresher
that captured every window forever, retaining one live IOSurface per window,
blew past that budget over a multi-day session → WindowServer crash.

Design that keeps us under budget:
- **`ThumbnailCache`** (`src/logic/ThumbnailCache.swift`): thread-safe per-window
  store + a min-heap scheduler. Tiers: `hot` (recency top-N, default 10), `warm`
  (shown), `cold` (off-screen/minimized). Cadence: 5s / 60s / 300s.
- **`BackgroundThumbnailRefresher`** (`src/logic/BackgroundThumbnailRefresher.swift`):
  500ms tick, pops due windows, skips minimized (frozen content), runs a ~30s
  **reconcile** (`removeZombieWindows`) so closed-without-AX-event windows release
  their surfaces, and emits the `THUMBCACHE` profiler line.
- **Detach for non-hot tiers** (`WindowCaptureEvents.swift` `ThumbnailBitmap`):
  warm/cold captures are copied into a **detached malloc bitmap** and the
  WindowServer IOSurface is released immediately. Only the bounded hot tier keeps
  live surfaces, so outstanding surfaces ≈ `bgThumbnailHotTierSize`, independent
  of how many windows are open.
- **Main-thread state snapshot** (`CaptureRequest`): per-window `size`/`scaleFactor`
  are snapshotted on the main thread before the concurrent `screenshotsQueue`
  runs, so the queue never reads main-owned `Windows.list`/`Window.size` (heap-race
  crash class).
- **`cachedSCWindows`** is lock-guarded; **`ActiveWindowCaptures`** is a
  token+watchdog counter; **`CGS_CONNECTION`** is computed (self-heals after a
  WindowServer restart).

**Leak watch:** the `THUMBCACHE` log line (perf level, ~every 30s) reports
`liveSurfaces`. It must hover near `bgThumbnailHotTierSize` and **not grow** with
the number of open windows. A rising `liveSurfaces` over a long session = the
leak regressed. Tunables: `bgThumbnail*` in `src/logic/Preferences.swift`.

Full incident write-up and the other capture-path fixes: `experiments/release-issue-monitor.md`
(REL-100/REL-101) and `experiments/release-risk-code-review.md` (Thumbnail/capture row).

## Diagnostics & profiling

`Diagnostics.log(category, message)` in `src/api-wrappers/Logger.swift` is
level-gated. Set the level with:
`defaults write com.lwouis.alt-tab-macos diagnosticsLevel <off|error|warn|info|perf|trace|verbose>`
(default `info`). `perf` adds switch timing, `REFRESH`, and `THUMBCACHE` counters;
`trace` adds z-order mechanics. Logs stream to `/tmp/alttab/latest.log` (and
`/tmp/alttab-run.log`). Always inspect the log, not just script exit codes.

## Build / test / run

- **Build/dev/install:** `bash ai/build.sh {compile|dev|install}` — the only
  supported loop. `compile` after every edit; `dev` for TCC-safe runtime tests;
  `install` only for shim/Pods/entitlements changes. (See `AGENTS.md`.)
- **Compile check (CI-style):**
  `xcodebuild -workspace alt-tab-macos.xcworkspace -scheme Debug -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- **Unit tests (24, pure-logic):**
  `xcodebuild test -workspace alt-tab-macos.xcworkspace -scheme Test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
  Cover Appearance, shortcut recorder, keyboard-events utils, search acronyms.
  They do **not** cover focus/capture — those are validated by the eval harness.
- **Profiling:** `ai/profile.sh` (Time Profiler / tracing).

## Eval harness & release gate (focus/z-order/capture correctness)

Mechanical unit tests can't prove focus/z-order/Coherence correctness. That is
what the `ai/` eval scripts + the release gate are for:
- **`experiments/release-issue-monitor.md`** — the canonical list of every known
  regression class (REL-001…), each with a failure signal, required checks, and
  current coverage. **Check changes against this before claiming a build good.**
- **`experiments/release-risk-code-review.md`** — maps release issues to risky code.
- **`experiments/focus-hypotheses.md`** — claims/hypotheses/evidence log (read before
  changing focus/z-order/latency/Coherence/display behavior).
- **`experiments/notebook.md`** — chronological experiment + profiler run history.
- **`ai/eval-*.sh`** — the live evals (focus transitions, rapid overlap, restart
  z-order, minimized order, copy-after-focus, thumbnail/window coverage, external
  launch). Guarded by `ai/eval-user-idle-guard.sh` and `ai/eval-popup-storm-guard.sh`
  (exit `86` = contaminated desktop, stop). Run each ≥3×; treat user activity as
  contamination. See `AGENTS.md` for the full required-checks list.

## Upstream

`upstream` = lwouis/alt-tab-macos, `origin` = this fork. See **[UPSTREAM.md](UPSTREAM.md)**
for the pull/merge workflow and the current divergence assessment.
