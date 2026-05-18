# AltTab Window-Switch Experiments — Self-Paced Loop

Current hypothesis/claim/evidence log: `experiments/focus-hypotheses.md`.

Self-paced /loop driving a sequence of A/B experiments while the user is away.
Goal: faster, more reliable transitions across Mac↔Mac, Par↔Par, Mac↔Par,
Par↔Mac without breaking the per-window focus invariant.

## Ground rules
- Do not regress the per-window focus invariant. SAMEAPP=N>1 in top-8 = regression.
- Don't push to remote. Don't close the user's apps. Builds + redeploys to
  /Applications/AltTab.app are reversible (custom-build.sh keeps a .bak).
- Each experiment changes **one** variable at a time. Always re-baseline after
  any wider refactor.
- Source of truth = Profiler summary in /tmp/alttab-run.log (since user can't
  drive Alt-Tab while away). Profiler picks targets from
  Windows.list at runtime; the candidate pool depends on what's currently open.

## Logging levels (added 2026-05-04)
`defaults write com.lwouis.alt-tab-macos diagnosticsLevel <level>`:
- `off`     — silent (back-compat with `diagnosticsEnabled=false`)
- `error`   — failures only
- `warn`    — anomalies (CLICKMISROUTE, FRONT_MISMATCH, TITLEMISS, AXTITLE failed, CLICKAFTER mismatch)
- `info`    — DEFAULT; PANEL/KEY/FOCUS/MOUSE/SESSION/INIT/MANUAL/HIDE/GUARD/TITLE + PROFILER summaries
- `perf`    — adds SWITCH timing & REFRESH counters
- `trace`   — adds z-order debugging (SYSZ/SAMEAPP/RECENCY/ZALIGN/ZENFORCE/ZRESTORE/FRONTMOSTSET/etc.)
- `verbose` — adds WINSIDE/API/CTAP

## Mac→Mac switch path (baseline understanding from logs through 2026-05-04 15:04)

Phase timings on `par=false` Mac→Mac switches, t0=key release:

| Phase | Δ from prev | What runs |
|---|---|---|
| `t0 [shortcut-up]` | 0 | hotkey released |
| `focusTarget` / `focusSelectedWindow` | <1ms | dispatch into App.focusSelectedWindow |
| `preHideUi` | ~0.3ms | branch decision |
| `preFocus par=false` | **25–75ms** | `hideUi(true)`: panel orderOut, event-tap teardown (CursorEvents, ContextMenuEvents), hideAllTooltips, MainMenu.toggle |
| `slpsDone` | 10–30ms | `_SLPSSetFrontProcessWithOptions` |
| `makeKeyDone` | 0–30ms | `makeKeyWindow` (SLPS event injection) |
| `axDone` (background queue) | +30–180ms after makeKey | `kAXRaiseAction` RPC |

User-perceived = t0 → makeKeyDone ≈ 50–135ms typical.
The hideUi block before SLPS is the largest controllable chunk.

## Open hypotheses (ranked by expected impact)

1. **H1 — Reorder Mac→Mac**: call `window.focus()` first, dispatch `hideUi(true)`
   ~16ms (one frame) later. Mirrors the Parallels branch which already proves
   this works without z-order regressions. Expected save: 25–75ms perceived.
   Risk: brief visible focus before panel disappears (might look fine since
   the target window animates underneath the popUpMenu-level panel).
2. **H2 — Background event-tap teardown**: in `hideUi`, defer
   CursorEvents.toggle(false) + ContextMenuEvents.toggle(false) +
   hideAllTooltips to the next runloop. Save: 5–20ms.
3. **H3 — Skip `_SLPSSetFrontProcessWithOptions` re-fire on same-pid Mac→Mac**:
   if target's pid matches `Applications.frontmostPid`, skip SLPS and call
   only `axUiElement.focusWindow()` synchronously inline. Save: 10–30ms.
   Risk: window doesn't get focus signal correctly. Need same-app data point.
4. **H4 — Inline AX focusWindow off background queue**: `axUiElement.focusWindow`
   is the ~50–150ms RPC. Already async. Probably correct as-is, but could test
   pre-warming the AX call mid-switch.

## Experiment log

### Run 0 — pre-instrumentation baseline (historical, before this loop)
- Source: 24h of /tmp/alttab-run.log up to 2026-05-04 15:04
- Mac→Mac t0→makeKeyDone: 50–135ms typical (manual switches)
- Per-window focus invariant holds: no SAMEAPP=N>1 lines in recent samples
- Latency distribution unknown (no profiler runs in this window)

### Run 1 — profiler baseline (current build, pre-H1)
- Build: 2026-05-04 15:10 (log-level system)
- Diagnostics level: perf
- Profiler: 60s, n=21 attempts
- Result: **21/21 (100%) at 50ms checkpoint, all 4 transitions stable @2s, 0% flicker**
- Distribution: parToPar=8, parToMac=5, macToPar=6, macToMac=2 (matches weighting)
- Conclusion: reliability is already 100% at the profiler's coarsest checkpoint.
  Latency floor is unmeasured (no sub-50ms checkpoints). User-perceived "slow"
  must be in 5-49ms window or in the panel-hide flash (not measured by Profiler).

### Run 2 — H1 reorder + finer checkpoints (this loop)
- Build: 2026-05-05 01:53 (pid 11009)
- Changes:
  1. Profiler offsets now [5, 10, 15, 20, 30, 40, 50, 100, 200, 500, 1000, 2000]
  2. Mac→Mac branch in `App.focusSelectedWindow`: focus() FIRST, then hideUi(true)
     (mirrors Parallels branch ordering; SLPS fires at t=0 instead of t=hideUi-cost)
  3. `captureTopZRanking` default bumped from 15→200 (full visible window
     ranking captured for ZRESTORE, addressing user note "not just top 8").
- Hypothesis: macToMac first-success drops from 50ms to ≤20ms.
- Risk: if hideUi->focus order matters, macToMac first-success may stay 50ms
  but stability could regress at later checkpoints.
- Profiler running; see next iteration for summary.

### Run 2 — RESULT (read 2026-05-05 ~02:00)
- 21/21 (100%) at every checkpoint from 5ms onward, except #1 (parToPar
  Outlook→Outlook): hit at +5...+50ms, FAILED at +100ms (`top:Outlook (classic)`),
  recovered at +200ms. Same pattern AGENTS.md flags as the parallels-coherence
  intra-app sibling bounce — ZENFORCE catches it.
- first-success ms: avg=5 p50=5 p90=5 (was 50/50/50 in Run 1; the pre-50ms
  detail was previously hidden by the coarsest checkpoint).
- per-app stability @2s: Edge 1/1, OneNote 4/4, Outlook 10/10, Safari 4/4,
  Terminal 2/2.
- macToMac: only 3 samples — low confidence. Bumped weight to 30% for Run 3.

Take-away: H1 reorder did not regress; the focus mechanism itself is sub-5ms.
The user-perceived improvement (eliminating the 25-75ms hideUi-before-SLPS gap
from the keyboard path) is not measurable with the current synthetic profiler
since it bypasses the keyboard handler. To measure it would require either
SWITCH-timing data from real user interaction or CGEventPost-based key
injection.

### Run 3 — bounce tracking + macToMac re-weight
- Build: 2026-05-05 02:01 (pid 11864)
- Result: 21/21 stable@2s, but **2/21 (10%) post-success bounces** in 10-50ms window:
  - #0 parToMac→Safari (74782), bouncer=OneNote (Parallels), 10/15/20ms `z!ax!`, recovered@30ms
  - #16 macToMac→Safari (39136) [via fastAltTab from Parallels intermediate],
    bouncer=Outlook (Parallels), 10/15/20/30/40/50ms `z!ax!`, recovered@100ms
- Bounce histogram: 10ms=2, 15ms=2, 20ms=2, 30ms=1, 40ms=1, 50ms=1
- Diagnosis: both bounces hit `focusMacOsWindowOverParallelsCoherence` and
  were rescued by the +1s FRONT_MISMATCH polling. ZENFORCE early-phase ticks
  start at +30ms — too late for the 10-25ms bounces. Mechanism is Parallels'
  coherence sync timer firing right after we focus a Mac target whose source
  was a Parallels window: Parallels briefly re-asserts the prior Coherence
  app's foreground state.

### Run 4 — tighten ZENFORCE early-phase
- Build: 2026-05-05 02:10 (pid 12852)
- Changes:
  1. `earlyOffsetsMs` in `Windows.startZOrderEnforcement`: was [30, 80, 150, 250,
     350, 450] → now [5, 12, 25, 50, 100, 200, 350].
- Result: **21/21 (100%) at every checkpoint, 0/21 post-success bounces** (vs 2/21 in Run 3)
- All 4 transitions clean; per-app: Edge 1/1, OneNote 2/2, Outlook 9/9, Safari 5/5, Terminal 4/4.
- Caveat: n=21 gives ~10% precision on bounce rate. Run 3's bounces could
  have been stochastic; need more samples to be confident.

### Run 5 — extended idle baseline
- Build: 2026-05-05 02:17 (pid 13817)
- Changes: `profilerDurationSeconds` UserDefault override; 180s
- Result: **63/63 (100%) at every checkpoint, 0/63 post-success bounces**
- Modes: tileClick 32/32, fastAltTab 31/31
- Transitions: parToPar 15/15, parToMac 10/10, macToPar 19/19, macToMac 19/19
- Conclusion: Run 4's tightened ZENFORCE early-phase fix is statistically robust
  at n=63 (~3% precision). No bounces, no flicker recoveries needed, no
  drift after first-success.

### Run 6 — load test under CPU stress
- Build: same as Run 5 (no code change)
- Setup: 8 `yes > /dev/null` processes (saturating ~8 of 18 cores).
  Top measured 36% user + 56% sys = 92% busy at startup.
- Profiler: 60s, n=22.
- Result: **22/22 (100%) at every checkpoint, 0/22 post-success bounces.**
  All 4 transitions: parToPar 5/5, parToMac 5/5, macToPar 7/7, macToMac 5/5.
- Conclusion: focus mechanism + ZENFORCE early-phase fix hold under
  ~50% CPU load. No checkpoints slipped enough to mask the focus completion.
  Note: `yes > /dev/null` saturates non-main cores; main-thread GCD scheduling
  isn't directly contended. For deeper main-thread stress would need either
  AltTab-internal busy-loops or a CGWindowList-spamming process.

### Run 7 — extended load test
- Build: same as Run 5/6 (no code change)
- Setup: 8 stressors with 200s self-kill; 180s profiler
- Result: **64/64 (100%) at every checkpoint, 0/64 post-success bounces.**
  All 4 transitions clean; tileClick 35/35, fastAltTab 29/29.
- Conclusion: post-fix system is robust at n=64 under 50% CPU load.

## Final cumulative results (post-H1 + post-ZENFORCE-tighten)

| Run | n | Conditions | Stable@2s | Bounces | Flicker |
|---|---|---|---|---|---|
| 4 | 21 | idle | 100% | 0% | 0% |
| 5 | 63 | idle | 100% | 0% | 0% |
| 6 | 22 | 8-core load | 100% | 0% | 0% |
| 7 | 64 | 8-core load (180s) | 100% | 0% | 0% |
| **Total** | **170** | mixed | **100%** | **0%** | **0%** |

First-success ms: avg=5, p50=5, p90=5 in every run (5ms is the profiler's
floor checkpoint; actual focus completion is sub-5ms).

## What's not yet measured

- **Keyboard-path latency** (the user's actual flow). Profiler bypasses the
  hotkey handler. Post-H1 SWITCH timing data will accumulate when user
  resumes manual AltTab use; can compare to pre-H1 traces from 2026-05-04
  14:31-15:04. Default diagnosticsLevel left at `perf` so timing logs
  continue to accrue.
- **Different Spaces / fullscreen target.** Profiler's `eligibleTargets`
  filter excludes minimized/hidden but doesn't exclude different-Space.
  Did not specifically stress this.
- **Long sessions / memory drift.** RSS at end of Run 7 = 522 MB after 10
  min uptime + 4 profiler runs. Not a leak; in line with thumbnail caching.
- **WindowServer-level contention.** `yes` saturates non-main CPU cores;
  doesn't directly contend with the WindowServer's IPC. A more aggressive
  test would spam CGWindowList from another process.

### Run 8 — A/B revert validation (INVALID — TCC lost)
- Build: 2026-05-05 03:13 (pid 17498)
- Hidden UserDefault `zenforceEarlyABMode` added; "slow" → old offsets
  [30, 80, 150, 250, 350, 450], "fast" (default) → new
  [5, 12, 25, 50, 100, 200, 350]. Same A/B knob flips without rebuilding.
- Result: profiler reported `candidates par=0 mac=0`; every transition
  retried indefinitely; FINISHED with 0 attempts. Cause was NOT the
  reverted offsets — `Windows.list` was empty because AltTab received
  zero AX events after launch. Subsequent re-launch of the same bundle
  (pid 17976) reproduced the symptom: only INIT lines emit, no
  `kAXApplicationActivated` / `kAXFocusedWindowChanged` arrive.
- Diagnosis: cumulative custom-build → install → restart cycles today
  (six rebuilds across iterations 1-9) invalidated AltTab's TCC
  Accessibility entry. macOS sometimes treats a rebuilt bundle as a
  new TCC client when code-signature timestamp/inode changes; the
  user-DB entry persists but the system-DB entry needs SIP to upsert.
- Recovery for the user when they return:
  1. System Settings → Privacy & Security → Accessibility → AltTab:
     toggle off, then on (or remove and re-add).
  2. Same for Screen Recording (only matters for thumbnails).
  3. Restart AltTab. Logs should resume showing AXEVENT/KEY/FOCUS.
- A/B test inconclusive — could not reproduce/refute Run 3 bounces.

### Run 8 verification — root cause confirmed
- Examined `src/logic/SystemPermissions.swift:42-55` — pre-startup check
  blocks `App.continueAppLaunchAfterPermissionsAreGranted()` when AX
  permission is denied. AltTab logs the launch banner and `continuous
  monitoring OFF` (both from `applicationDidFinishLaunching`) BEFORE the
  permissions check runs, so an INIT-only log followed by silence is the
  exact signature of "AltTab launched, permission check failed,
  permissions window opened, app waiting." The permissions window is on
  screen invisibly because LSUIElement.
- I cannot trigger a TCC re-grant from this session (system DB is
  SIP-protected; user DB writes don't restore the server-side observer
  registration). User action required.

## Conclusion of this self-paced loop session

System is in a good state CODE-WISE: every change shipped this loop is
documented above and validated through Run 4-7 (170/170 stable, 0
bounces). The TCC issue at the end is purely an environmental side
effect of frequent rebuilding — it does not invalidate the earlier
results, since those runs (4-7) all happened with the rebuild chain
still active and TCC working.

Code state in /Applications/AltTab.app: build 2026-05-05 03:13 with
- log levels (Diagnostics.Level)
- H1 Mac→Mac focus-first reorder
- updateFromAxAttributes debugId sync
- captureTopZRanking depth 200
- ZENFORCE early-phase [5, 12, 25, 50, 100, 200, 350]
- Profiler: finer checkpoints, bounce tracking, configurable duration,
  zenforceEarlyABMode A/B knob

Defaults left set:
- diagnosticsLevel = perf
- zenforceEarlyABMode = fast (production)
- runProfilerAtLaunch unset
- profilerDurationSeconds unset

## Defaults left set for the user

- `diagnosticsLevel = perf` — captures SWITCH timing on real keyboard
  switches; quiet enough for daily use. Change with
  `defaults write com.lwouis.alt-tab-macos diagnosticsLevel info`.
- `runProfilerAtLaunch = 0`, `profilerDurationSeconds` unset — clean.
- `overlayMode = 0` — unchanged.

## Combined results (post-fix runs)

| Run | n | Conditions | Stable@2s | Bounces |
|---|---|---|---|---|
| 4 | 21 | idle | 21/21 (100%) | 0/21 (0%) |
| 5 | 63 | idle | 63/63 (100%) | 0/63 (0%) |
| 6 | 22 | 8-core load | 22/22 (100%) | 0/22 (0%) |
| 7 | ~60 | 8-core load (180s) | TBD | TBD |
| **Total (4-6)** | **106** | mixed | **106/106 (100%)** | **0/106 (0%)** |

## Cumulative changes shipped this loop

1. **Log levels** (`diagnosticsLevel` UserDefault, off/error/warn/info/perf/trace/verbose).
   Default `info` is quiet by design — diagnostics-on-demand without removing code.
2. **`updateFromAxAttributes` syncs debugId with title.** Stops focus-log/RECENCY
   drift on Coherence pages where AX title-changed events fire.
3. **H1: focus-first / hide-after for Mac→Mac.** SLPS fires at t=0 instead of after
   ~25-75ms hideUi work. Same ordering the Parallels branch already used.
4. **Profiler: finer checkpoints + bounce tracking.** Offsets [5, 10, 15, 20,
   30, 40, 50, 100, 200, 500, 1000, 2000]; macToMac=30% weight; bounce
   histogram + z-vs-AX failure disambiguation; configurable duration via
   `profilerDurationSeconds`.
5. **`captureTopZRanking` default 200 (was 15).** Full-depth preZ snapshot
   so ZRESTORE corrects below position 15 too. Addresses user's note that
   "true z-order" must not be top-N truncated.
6. **ZENFORCE early-phase ticks tightened** [30,80,150,250,350,450] →
   [5, 12, 25, 50, 100, 200, 350]. Catches the +10-25ms Parallels-coherence
   bounce that profiler Run 3 surfaced.

## Runtime perf toggles added 2026-05-18

Use these with `defaults write com.lwouis.alt-tab-macos ...` for A/B timing without source edits:

- `diagnosticsBasicPerfOnly -bool true` — with `diagnosticsLevel=perf`, logs only `SWITCH`, `REFRESH`, `AXFOCUS`, and `LOGCOST` plus warnings/errors.
- `thumbnailCaptureEnabled -bool false` — disables thumbnail screenshot capture requests.
- `focusOverlayCaptureEnabled -bool false` — disables focus-overlay pre-capture/background capture.
- `zOrderCacheEnabled -bool false` — disables background z-order cache refresh/review work.
- `zOrderFixesEnabled -bool false` — disables active z-order repair/enforcement while leaving ordinary focus paths intact.
- `nativeFocusMode userGeneratedFocus|noWindowsFocus|noWindowsRaise|userGeneratedRaise|originalAltTab|skyLightEventFocus|noWindowsAxActivateClickFallback|hidTitlebarClick` — native Mac focus experiment switch.
- `nativeFocusClickFallbackDelayMs -int 60` — delay before the guarded no-cursor click fallback checks z0 and posts `CGPostMouseEvent`.

Current normal-runtime reset after the low-overhead tests:

- `nativeFocusMode = noWindowsAxActivateClickFallback`
- `nativeFocusClickFallbackDelayMs = 60`
- `nativeMultiWindowAxTimeoutMs = 50`
- `thumbnailCaptureEnabled = true`
- `focusOverlayCaptureEnabled = true`
- `zOrderCacheEnabled = true`
- `zOrderFixesEnabled = true`
- `captureWindowsInBackground = true`
- `diagnosticsLevel = perf`
- `diagnosticsBasicPerfOnly = true`

## True z-order tracking — coverage audit (added this iteration)

Source-of-z-order-change → AltTab observation path:

| Event | Path | Notes |
|---|---|---|
| App launched from Spotlight/cli | `kAXApplicationActivatedNotification` → `applicationActivated` → `updateLastFocusOrder` | AccessibilityEvents.swift:47 |
| User clicks window in different app | `kAXApplicationActivated` + `kAXFocusedWindowChanged` | both fire; updateLastFocusOrder |
| User clicks window in same app | `kAXFocusedWindowChanged` only | AccessibilityEvents.swift:189 |
| New window opened | `kAXWindowCreatedNotification` → `findOrCreate` → `appendWindow` | inserted at *end* of recency, not at #0 (Windows.swift:1273) |
| Window closed | `kAXUIElementDestroyedNotification` → `windowDestroyed` → `removeWindows` | recency re-numbered |
| Window minimized/zoomed | `kAXMainWindowChangedNotification` | re-routed to focusedWindowChanged |
| App quit | `NSWorkspace.didTerminate` (Applications.swift) | windows removed |
| AltTab focus | `armAltTabFocusGuard` + `Window.focus()` | preZ snapshot taken |

ZRESTORE preZ snapshot was capturing only top-15. Bumped to 200 this iteration so
corrections below the visible-fold reflect the user's expected order.

## Open hypotheses (updated)

1. ~~**H1**~~ — applied this iteration. Re-test result pending profiler.
2. **H2** — Background event-tap teardown in `hideUi`: defer
   CursorEvents.toggle(false) + ContextMenuEvents.toggle(false) +
   hideAllTooltips. With H1 in place, hideUi runs AFTER focus, so the
   teardown latency no longer blocks focus. H2 may be unnecessary now.
3. **H3** — Skip `_SLPSSetFrontProcessWithOptions` re-fire on same-pid
   Mac→Mac (target's pid == frontmostPid). Save: 10–30ms.
4. **H4** — Pre-warm AX `focusWindow` call mid-switch (probably not needed;
   already async on background queue and doesn't block user perception).
5. **NEW H5** — H1 reorder for **Parallels paths too**. Currently the
   Parallels branch already focuses first (different code path); but the
   `Window.focus()` itself does not call `armAltTabFocusGuard` for
   Mac→Mac. Audit Window.focus() variants for any blocking work that
   could move to async.

## 2026-05-18 late — no-cursor click fallback results

- Modern `CGEvent(... mouseCursorPosition ...)` plus `.cghidEventTap` reproduces the fast WindowServer click path but moves the cursor. Delayed cursor warps can restore it, but there is visible/racy pointer movement.
- Runtime `dlsym("CGPostMouseEvent")` still succeeds even though the macOS 26.5 SDK marks it unavailable. Calling it with `updateMouseCursorPosition=false` activates the clicked window and leaves the cursor fixed.
- Implemented guarded fallback:
  - mode: `nativeFocusMode=noWindowsAxActivateClickFallback`
  - fallback delay: `nativeFocusClickFallbackDelayMs=60`
  - only posts when target is not z0 and the candidate titlebar point resolves to the target as the top routable window.
- Final direct matrix: Terminal→Safari median 0.05ms, worst 181.68ms; Safari→Terminal median 0.07ms, worst 200.04ms. Prior guarded no-windows path had 300-500ms outliers.
- Same-app Terminal check after Safari→Terminal: z0 selected Terminal, z1/z2 Safari, other Terminal windows below Safari. No all-Terminals-to-front regression observed in this check.

## 2026-05-18 final — post-profile cleanup

- `sample` found one real self-inflicted issue: +200ms `CLICKAFTER` diagnostics were doing `AXUIElementCopyAttributeValue` on the main thread after clicks, even when no mismatch needed to be logged.
- Patched `App.swift` so the main thread only checks the cheap frontmost pid; AX focused-window lookup now runs on `BackgroundWork.accessibilityCommandsQueue` and only for actual mismatch logs.
- Rebuilt and restarted dev AltTab with `nativeFocusMode=noWindowsAxActivateClickFallback`, `nativeFocusClickFallbackDelayMs=60`, `diagnosticsLevel=perf`, `diagnosticsBasicPerfOnly=true`.
- Final direct run `/tmp/alttab-profile/dynamic-focus-clickfallback80-20260518_042143.json`: Terminal→Safari median 0.06ms/worst 116.17ms; Safari→Terminal median 0.13ms/worst 196.62ms.
- Final hotkey run `/tmp/alttab-profile/dynamic-hotkey-clickfallback80-20260518_042354.json`: 18/18 successful across 20/45/100ms key speeds; worst z0 278.48ms.
- Same-app Terminal direct focus check: focusing Terminal `130062` then returning to `130253` put only those two recent Terminal windows at z0/z1, Safari at z2/z3, and the rest of the Terminal stack below Safari. This did not reproduce the all-Terminals-to-front regression.

## 2026-05-18 — stuck input capture freeze

- Symptom: user reported AltTab prevented clicking other apps, making the UI effectively frozen until AltTab was killed from another account.
- Log reconstruction:
  - `/tmp/alttab-run.log` only covered older PID `1405`; the current dev run was foreground logging through Codex.
  - Recovered PID `34492` logs from the running exec session; the process kept logging `REFRESH reason=window-moved-resized` until SIGTERM at 11:40.
  - There were no global `MOUSE` down logs while the user was clicking. Since AltTab's global monitor does not see events swallowed by the CGEvent tap, this is strong evidence that `CursorEvents` was still enabled and absorbing clicks.
- Root-cause assessment:
  - AltTab did not crash or stop its main runloop.
  - The desktop looked frozen because input capture stayed armed while the panel/session state did not exit normally.
  - Risky paths included outside mouse-down absorption without immediate hide, right/other click absorption, async tap disable in `hideUi()`, and duplicate focus debounce returning without release.
- Patch:
  - `hideUi()` now disables `CursorEvents` and resets trackpad capture synchronously before hiding the panel.
  - All outside mouse-downs hide UI immediately. If capture is stale for more than `inputCapturePassthroughMs`, the event passes through after hiding instead of being swallowed.
  - `inputCaptureWatchdogMs` starts when AltTab enters capture mode and force-hides any session that remains open too long.
  - Duplicate focus debounce now calls `hideUi(true)` before returning.
  - Added `CAPTURE` diagnostic category and defaults for `inputCaptureWatchdogMs=15000`, `inputCapturePassthroughMs=3000`.
- Validation:
  - `bash ai/build.sh compile` succeeded.
  - `bash ai/build.sh dev` built `dev/AltTabCore.dylib`.
  - Temporarily set `inputCaptureWatchdogMs=2000`, launched dev AltTab, forced `--show=0`, and observed `[DIAG CAPTURE] watchdog hiding stuck input capture after 2000ms`.
  - Restored defaults to `inputCaptureWatchdogMs=15000` and `inputCapturePassthroughMs=3000`.

## 2026-05-18 — Par↔Mac flashing regression

- Symptom: user reported Parallels↔Mac flashing returned and had been better before the last few fixes.
- First check: live logs showed Par↔Mac still went through the Parallels-specific paths (`parToMac`, `atomicallyPinAndActivate`), not the native `noWindowsAxActivateClickFallback`, so the Safari click fallback was not directly responsible.
- Likely cause: the Parallels curtain had been shortened from the old 200ms to 30ms for all Parallels-involved transitions. Current logs showed Par→Mac app/focused-window notifications commonly arriving hundreds of milliseconds after SLPS/AX focus, so dropping the panel after ~30ms can expose Parallels' intermediate redraws.
- Patch:
  - added `parCrossBoundaryHideUiDelayMs=200`,
  - added `parSameBoundaryHideUiDelayMs=30`,
  - changed `App.focusSelectedWindow` to use 200ms only when `sourceIsPar != targetIsPar`,
  - kept existing `parHideUiDelayMs` as a manual global override,
  - added `parHideScheduled` `SWITCH` timing marker.
- Runtime state:
  - deleted the temporary global `parHideUiDelayMs` override,
  - set `parCrossBoundaryHideUiDelayMs=200`,
  - set `parSameBoundaryHideUiDelayMs=30`.
- Validation:
  - `bash ai/build.sh compile` succeeded.
  - `bash ai/build.sh dev` built `dev/AltTabCore.dylib` cdhash `36a76d6755180ffc50c38b8a50a6f5a39a2b1704`.
  - Foreground dev launch is running as PID `19640`.
  - Three simulated Cmd-Tab hotkeys produced:
    - `parHideScheduled ... 200ms sourcePar=true targetPar=false`,
    - `parHideScheduled ... 200ms sourcePar=false targetPar=true`.

## 2026-05-18 — Par hide readiness gate

- User still saw flashing with the fixed 200ms cross-boundary curtain.
- Added `/tmp/alttab_zsample` Swift sampler for external WindowServer evidence. It samples top visible app window every 10ms and prints only top-window changes.
- Reproduced the gap:
  - Par→Mac controlled sample: Teams stayed top until about 490ms after hotkey in one run.
  - Mac→Par controlled sample: Terminal stayed top until about 346ms after hotkey in one run.
  - App logs aligned with this: `parHideScheduled 200ms` fired long before `app-activated`/visible handoff in some runs.
- Patch:
  - `App.focusSelectedWindow` cancels delayed panel display after focus is committed.
  - Par-involved hide now polls the top visible app window and hides only once the target `CGWindowID` is topmost and min delay has elapsed.
  - Added max/poll defaults: `parHideMaxDelayMs=1200`, `parHidePollIntervalMs=25`.
  - Added `parHideNow` switch marker with elapsed time, readiness, target, and current top window.
- Validation:
  - `bash ai/build.sh compile` succeeded.
  - `bash ai/build.sh dev` built `dev/AltTabCore.dylib` cdhash `700854c2b078874e5592471525ee31112b8f53fc`.
  - Foreground dev launch is running as PID `22341`.
  - Six sampled Par↔Mac reps had exactly one app-top transition and no bounce back:
    - Par→Mac top transition samples: ~396ms, ~403ms, ~411ms after sampler start.
    - Mac→Par top transition samples: ~531ms, ~608ms, ~608ms after sampler start.
  - Matching AltTab logs for these reps all hid with `parHideNow ... ready=true`; no timeout hide was observed.

## 2026-05-18 — native Mac focus/copy regression follow-up

- Added high-resolution z-order evaluators:
  - `ai/z-order-sampler.swift` samples WindowServer order at millisecond cadence and records target z, same-app-above counts, same-app top-8 counts, and top window IDs.
  - `ai/eval-focus-transition.sh` wraps exact `--focus=<wid>` calls, supports `TARGET_INDEX`/`TARGET_WID`, and reports first z0, post-z0 flicker, final top-8, and sibling intrusions above the pre-focus divider.
  - `ai/eval-copy-after-focus.sh` focuses Safari, posts `Cmd-L`/`Cmd-C` with explicit modifier release, and verifies the pasteboard equals Safari's URL.
- Copy/paste root cause:
  - AltTab's keyboard sniffing is not swallowing `Cmd-C`; the global modifier tap is listen-only and hotkeys are Carbon global shortcuts.
  - The reproducible failure was focus state: `originalAltTab` sometimes made Safari visually z0 before Safari was actually key/front enough to receive `Cmd-L`/`Cmd-C`.
  - Stale synthetic modifier state was an earlier test artifact; `ai/post-key-combo.swift` releases Tab/Command/Shift/Option/Control before and after every probe.
- Matrix after adding the evaluator:
  - `originalAltTab` Safari z0 reps: about 530-1100ms; one `eval-copy-after-focus` probe at 0.8s failed because the front app was still Terminal.
  - `skyLightEventFocus` Safari z0 reps: about 61-89ms; Safari copy passed 3/3.
  - Deeper Safari-window probes showed no post-z0 sibling intrusion above the pre-focus divider.
  - Restart probe showed AltTab launch did not change Safari z-order; the before/after top-8 was identical.
- Patch:
  - Terminal/iTerm routing now happens before `nativeFocusMode`, so `skyLightEventFocus` cannot bypass the target-only no-windows path.
  - `nativeFocusMode` default is now `skyLightEventFocus` for non-Terminal native Mac windows.
  - Terminal/iTerm keep the target-only `nativeMultiWindow` path to avoid bringing every terminal window forward.

## 2026-05-18 — late sibling overtakes caught by z evaluator

- The stricter evaluator caught two regressions that ordinary timing logs missed:
  - Safari target reached z0 in ~76ms, then a Safari sibling overtook it at ~+1175ms.
  - Terminal target reached z0, then a Terminal sibling overtook it at ~+311ms.
- Root cause split:
  - Native focus paths were not arming any z-order enforcement, so delayed app/window activation could promote a sibling after the target initially succeeded.
  - `SLEventPostToPid` synthetic focus clicks also hit AltTab's global mouse monitor at the stationary cursor position; the monitor resolved the cursor location to Terminal and treated it as a real user click, canceling the enforcement intent.
- Patch:
  - added `Windows.armNativeFocusZOrderIntent(for:preZ:)`, which records a pre-focus z snapshot and runs the existing z enforcement without setting the input-capture/focus-order guard,
  - applied it to `skyLightEventFocus` and Terminal/iTerm target-only focus,
  - added synthetic focus-click ignore state so AltTab's global mouse monitor does not update user-click state or release enforcement for its own no-cursor click events,
  - added user-click release for native z enforcement so a real click still stops the short-lived repair loop.
- Final validation:
  - Safari z0 reps: ~129ms, ~80ms, ~97ms, ~85ms; no post-z0 flicker or sibling intrusion.
  - Safari copy probes: passed with `DELAY=1.2`.
  - Terminal z0 reps: ~188ms and ~159ms; no post-z0 flicker or sibling intrusion.
  - Restart probe: top-8 order unchanged across restart; launch did not move Safari windows.

## 2026-05-18 — three-clean-run validation rule

- Added the standing rule to `AGENTS.md` and `experiments/focus-hypotheses.md`: UI/focus/z-order checks need at least three clean repetitions before trusting the result.
- Rationale: unattended runs can overlap with real user input. A concrete example occurred during copy validation: Safari reached z0, then a real/global mouse-down landed on Terminal 1359ms after focus and made the copy probe report `front=Terminal`. The run was marked contaminated instead of treated as an AltTab regression.
- Fixed one test artifact before rerunning: `ai/post-key-combo.swift` now releases modifiers before Tab, preventing synthetic `Option+Tab` state from triggering AltTab's `nextWindowShortcut` during copy probes.
- Clean validation after rebuilding and launching the dev dylib through LaunchServices:
  - Safari focus z0: 78.2ms, 67.1ms, 65.0ms.
  - Safari copy after focus: 3/3 passed at `DELAY=1.2`.
  - Terminal focus z0: 219.2ms, 161.9ms, 224.1ms.
  - All six z-order focus checks had `flicker_after_z0_samples=0` and `sibling_intrusions_after_z0_max=0`.
- Process left running: `/Applications/AltTab.app/Contents/MacOS/AltTab --logs=warning` with `ALTTAB_DYLIB_OVERRIDE=dev/AltTabCore.dylib`.

## 2026-05-18 — hotkey probe safety stop

- Attempted to add a real hotkey-path evaluator because exact `--focus` does not fully cover flicker/perf in the switcher UI path.
- First attempt was invalid: it assumed `Option+Tab`, but this machine's `holdShortcut` is configured as Command. Several samples therefore did not exercise AltTab as intended.
- User observed that switching back to Terminal during tests routed input to Terminal. Testing was stopped immediately and all evaluator/sampler helper processes were killed.
- Added a hard safety guard to `ai/eval-hotkey-transition.sh`: it refuses to post global hotkeys unless `ALLOW_SYNTHETIC_HOTKEY_TESTS=1`, and refuses live Terminal hotkey tests unless `ALLOW_TERMINAL_HOTKEY_TESTS=1`.
- Added the same rule to `AGENTS.md` and `experiments/focus-hypotheses.md`: do not run synthetic hotkey tests against the user's live Terminal/session; use an isolated test desktop/window or exact-focus probes.

## 2026-05-18 — Shift probe and safe panel-driven validation

- Added a harmless focus probe: `ai/post-shift-probe.swift` posts only Shift down/up. It validates keyboard focus without sending printable input, Enter, or Tab to Terminal.
- Added `ai/eval-switch-transition.sh`, which exercises the actual AltTab panel/session path through CLI commands (`--show=0`, `--selection-state`, `--focus-target`) without posting global hotkeys.
- Sacrificial native apps:
  - spawned `AltTabEvalA` and `AltTabEvalB`,
  - enabled Shift probe logging to `/tmp/alttab-eval-keys.log`,
  - ran 18 panel-driven A↔B switches across 20/45/100ms show-to-focus delays,
  - all 18 passed with target final z0, no flicker, no source reappear, no sibling intrusion, and Shift delivered to the target app.
- Terminal/Safari exact window validation with Shift:
  - Terminal(130253)→Safari(125024): 148.9, 247.0, 278.3ms to target z0.
  - Safari(125024)→Terminal(130253): 539.1, 367.7, 235.2ms to target z0.
  - All six runs had `flicker_after_z0_samples=0`, `source_reappears_after_z0_samples=0`, and `sibling_intrusions_after_z0_max=0`.
- Copy regression check:
  - `DELAY=1.1 bash ai/eval-copy-after-focus.sh Safari` passed 3/3.
  - Pasteboard bytes matched Safari's expected toolbar URL each time.
- Recency/z-order smoke:
  - Focus OneNote(132443), then Safari(125024), then show AltTab.
  - Passed 3/3: selected index 1 was OneNote and top window stayed Safari. This verifies stale Terminal/Outlook source state is not being promoted after direct external focus changes.
- Parallels/native boundary:
  - OneNote(132443)→Safari(125024) after target-only Par→Mac z repair: later reps reached target z0 at 716.8 and 870.5ms, no flicker/sibling intrusion.
  - Outlook(132442)→Safari(125024): 391.9, 785.3, 165.5ms, no flicker/sibling intrusion.
  - Conclusion: Par→Mac visible handoff remains variable, but the current readiness gate prevents the old-window flash; the remaining delay is downstream WindowServer/Parallels/app surfacing, not AltTab main-thread blocking.

## 2026-05-18 — Instruments / xctrace profile

- Ran an attached Instruments Time Profiler capture against live AltTab PID 87720:
  - command shape: `xcrun xctrace record --template 'Time Profiler' --attach <pid> --time-limit 16s`,
  - trace: `/tmp/alttab-profile/alttab-timeprof-20260518_153907.trace`,
  - export: `/tmp/alttab-profile/alttab-timeprof-20260518_153907-time-profile.xml`.
- Drove two safe CLI panel switches during the capture:
  - Terminal(130253)→Safari(125024): first target z0 at 210.1ms; no post-z0 flicker, source reappear, or sibling intrusion.
  - Safari(125024)→Terminal(130253): first target z0 at 424.5ms; no post-z0 flicker, source reappear, or sibling intrusion.
- Aggregated Time Profiler samples:
  - main thread had 367/1817 samples; top AltTab work was UI refresh/layout/rendering (`App.refreshUi`, `TilesView.updateItemsAndLayout`, `TilesView.resolveAutoSize`, `TileTitleView.draw`, `StatusIconsView.layoutIcons`) and some `Windows.enforceZOrder`/`captureTopZRanking`,
  - background worker threads were dominated by AX brute-force window scans (`AXCallScheduler`, `Applications.manuallyUpdateWindows`, `AXUIElementRef.windowsByBruteForce`, `AXUIElementRef.attributes`) and z-cache `CGWindowListCopyWindowInfo` parsing,
  - CLI evaluator requests showed JSON encoding work on `cliMessages`.
- Interpretation:
  - no evidence of lock contention or a long synchronous main-thread focus block during the measured switches,
  - remaining visible handoff time is not AltTab CPU-bound in this profile,
  - UI layout/render cost remains worth optimizing for show latency, but it is separate from the observed WindowServer/app z0 handoff delay.
- Attempted an all-process Time Profiler run to include WindowServer/Safari/Terminal. It exceeded the requested 14s limit and had to be killed. Treat all-process Instruments as manually supervised only; do not use it in unattended test loops.
