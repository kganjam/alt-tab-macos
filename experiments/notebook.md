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

## 2026-05-19 — rollback of unsafe native focus experiments and final validation

- Starting state: an experimental dev build with native level pinning, dense Terminal repokes, and z0 activation click fallback left the desktop in split-brain z-order: Safari was the front process, but Terminal windows were visually top. Stopped AltTab, reset window levels, and activated Safari to recover normal visual layering.
- Reverted unsafe app behavior:
  - removed native target level pinning and delayed restore bookkeeping,
  - removed dense `nativeMultiWindowRepoke` timers,
  - removed z0 activation click fallback,
  - restored `nativeFocusClickFallbackEnabled=false`,
  - kept the previously validated Terminal/iTerm target-only focus path.
- Kept/fixed safer pieces:
  - Carbon front-process sampling in `ai/z-order-sampler.swift`,
  - exact `--select`/`--select-index` CLI support for panel-driven evaluators,
  - post-AltTab stale source-event suppression, tightened so target-pid events are not suppressed,
  - evaluator wrapper that strips shim banner text before piping CLI JSON to `jq`.
- Found a false-negative source in validation: Safari exposed `wid=141927`, a `1451x20` empty layer-0 helper strip, above the selected document window. It was not a real app window, but the sampler and repair logic counted it. Updated filters to ignore windows with either dimension <40.
- Build/runtime:
  - `bash ai/build.sh compile` succeeded after code edits,
  - `bash ai/build.sh dev` produced `dev/AltTabCore.dylib` cdhash `425ceaeaa660c3cdf62af5be9bb8204f76bd6429`,
  - the build-script background launch exited on this machine; direct launch stayed running: `ALTTAB_DYLIB_OVERRIDE=dev/AltTabCore.dylib /Applications/AltTab.app/Contents/MacOS/AltTab --logs=perf`.
- Validation files and results:
  - Terminal→Safari: `/tmp/alttab-select-zorder-20260519-022143.jsonl`, `...022148.jsonl`, `...022153.jsonl`; all pass, z0 1214.9/817.7/1570.0ms, no flicker/source reappear/sibling intrusion.
  - Safari→Terminal: `/tmp/alttab-select-zorder-20260519-022157.jsonl`, `...022202.jsonl`, `...022207.jsonl`; all pass, z0 535.5/706.3/646.4ms, no flicker/source reappear/sibling intrusion.
  - OneNote→Safari: `/tmp/alttab-select-zorder-20260519-022227.jsonl`, `...022233.jsonl`, `...022239.jsonl`; all pass, z0 400.2/1299.3/702.8ms, no flicker/source reappear/sibling intrusion.
  - Safari→OneNote: `/tmp/alttab-select-zorder-20260519-022245.jsonl`, `...022250.jsonl`, `...022256.jsonl`; all pass, z0 494.6/473.2/431.8ms, no flicker/source reappear/sibling intrusion.
  - Safari copy regression: `DELAY=1.2 bash ai/eval-copy-after-focus.sh Safari` passed 3/3 with pasteboard bytes matching the expected URL each time.
- Interpretation:
  - The recent flicker/regression risk came from the attempted native compositor interventions, not from the validated target-only path.
  - Current correctness looks good across native↔native and Parallels↔native panel-driven paths.
  - Terminal→Safari can still take more than a second for visual z0, but AltTab’s logged focus calls complete in tens of milliseconds and the target does not oscillate after it reaches z0.

## 2026-05-19 — evaluator hardening after missed rapid-overlap failure

- Found why a visible issue was not caught:
  - rapid run `rapid-overlap-20260519-025812-10827` wrote its marker, then the logged AltTab process restarted later; the old log scanner selected the wrong/empty region and printed `lines=0 failures=0`,
  - the z-order sampler did catch the real failure: final front process was Terminal while the visual top window stayed OneNote and the target Terminal window never reached z0,
  - the marked log region also contained repeated `stuck-popup detection` lines and real mouse events, so the run was contaminated and should never have been accepted as clean evidence.
- Hardened evaluators:
  - `ai/eval-log-anomalies.py` now supports `--end-marker`, fails restarts after markers, fails missing focus-path logs when an expected final window is supplied, fails stuck-popup flushing, and can fail mouse/key contamination,
  - `ai/eval-select-transition.sh` and `ai/eval-rapid-overlap-transition.sh` now write bounded start/end markers, persist `*.zscan.txt` and `*.logscan.txt`, assert final visual top window and front-process agreement, and run stale-event scans per rep,
  - `ai/eval-focus-regression-suite.sh` now runs all reps even after failures, stores child artifacts under the suite directory, generates a prompt review with the actual z/log scan files, and exits nonzero if any rep or scan fails.
- Safety fix:
  - live AltTab PID 11168 was stopped after it killed UserNotificationCenter/usernotificationsd every 10s due the stuck-popup watcher,
  - changed `flushStuckAuthPopupsThreshold` default to `0` and set the local default to `0`; automatic popup flushing is now opt-in only.

## 2026-05-19 — native slow-path cleanup and final validation

- Cleaned lingering native focus experiments before final validation:
  - reset local defaults to `nativeFocusMode=original`, `diagnosticsLevel=perf`, and deleted persisted `nativeExperimentalFocusModesEnabled`, `nativeNoWindowsFocusEnabled`, `fastZOrderNativeMonitorEnabled`, and `fastZOrderSyntheticClickEnabled`,
  - made `nativeExperimentalFocusModesEnabled=false` the code default so persisted `nativeFocusMode=skyLightEventFocus` cannot silently keep the app on a slow experimental path,
  - made `nativeNoWindowsFocusEnabled=false` the code default so Terminal/iTerm do not use the no-windows experiment unless explicitly enabled.
- Native Safari↔Terminal evidence:
  - `CGSOrderWindow(target, above, 0)` repeatedly returned `err=1000`; direct z-order correction is rejected by WindowServer for these windows,
  - background native fast z-monitor fired and queued repairs, but repeated `CGWindowListCopyWindowInfo` scans were sometimes 25-300ms and did not reduce visible z0 enough to justify default native monitoring,
  - `hidTitlebarClick` no-cursor experiment failed source-readiness checks by leaving visual top and front-process signals split; not safe as default,
  - skipping `refreshOpenUiAfterExternalEvent()` while AltTab is actively focusing removed redundant panel rebuilds from the focus path.
- Current running build:
  - `bash ai/build.sh compile` passed,
  - `bash ai/build.sh dev` launched PID 87707 through the installed shim with `ALTTAB_DYLIB_OVERRIDE=dev/AltTabCore.dylib`,
  - dev dylib cdhash `45b874e45b0c27718484b44e2c30b288dd91ade6`.
- Final artifacts: `/tmp/alttab-final-20260519-051754`.
  - Safari→Terminal: pass, z0 1315.7ms for a deep target and 444.0ms for immediate previous target; zero flicker-after-z0/source-reappear/sibling-intrusion samples.
  - Terminal→Safari: pass, z0 1453.6ms; zero flicker-after-z0/source-reappear/sibling-intrusion samples.
  - Rapid Safari→OneNote→Terminal: pass, final Terminal z0, no source/first-target reappear after z0, zero log failures.
- Operational note: the repeated unified-exec warning is not correlated with live eval/profiling processes after subagents were closed; `pgrep` showed one AltTab instance and no active eval jobs. Continue avoiding long-lived shell sessions.

## 2026-05-19 — Karabiner `fn+o` / Parallels Outlook Classic stale restore

- Correction from user: `fn+o` is a Karabiner hotkey for Parallels Outlook Classic, not Mac Outlook. The active Karabiner config runs `/Users/kganjam/bin/focus-parallels-outlook`, which opens `/Users/kganjam/Applications (Parallels)/.../Outlook (classic).app` and raises the `Outlook (classic)` Explorer window via AX.
- Root cause reproduced with corrected target:
  - pre-fix corrected eval marker `external-launch-20260519-111750-75265` showed AltTab `FRONT_MISMATCH` restoring the previous Terminal target after Outlook Classic became frontmost,
  - the stale target was Terminal `wid=130253`/`wid=118671`; frontmost was Outlook Classic `pid=96043`; AltTab re-issued `SLPS(userGenerated)+AX` to Terminal,
  - this explains “Outlook never came to front”: Karabiner did focus Outlook, then AltTab’s stale z-order enforcement fought the external focus and put Terminal back.
- Fix implemented:
  - track non-AltTab keyboard activity as external user intent,
  - release stale `recentZOrderIntents`, `altTabFocusTarget`, and z-order timers when external keyboard activity arrives after an AltTab focus intent,
  - also release on a subsequent external app activation/front-mismatch if it follows that keyboard activity,
  - log the release at default `GUARD` level so it is visible without trace logs.
- Evaluator hardening:
  - added `ai/eval-external-launch-transition.sh` for external app/hotkey paths that must not call AltTab focus,
  - added `ai/post-modifier.swift` so the eval can post Shift down/up as a harmless external-key signal before launching the Karabiner target,
  - added `--fail-front-restore` to `ai/eval-log-anomalies.py`, and the external eval now fails if any `FRONT_MISMATCH` restore fires.
- Validation:
  - negative control without simulated external key still reproduced the stale restore: `/tmp/alttab-karabiner-outlook-nosim-20260519-113232`, `eval_rc=1`, repeated `FRONT_MISMATCH ... restoring` Terminal over Outlook Classic,
  - final keyed run passed: `/tmp/alttab-karabiner-outlook-final-20260519-113457`, `eval_rc=0`, Outlook Classic first z0 at `589.836ms`, zero post-z0 flicker samples, final visual top and focused app both Outlook Classic, and bounded log scan failures/warnings were zero,
  - final run logged `released stale z-order enforcement by external keyboard ... target=#130231 age=1189ms`, and no `FRONT_MISMATCH` restore fired after the marker.
- Testing lesson: generic `TARGET_OWNER=Outlook` is ambiguous on this machine. Always use `TARGET_OWNER="Outlook (classic)"` plus `LAUNCH_COMMAND=/Users/kganjam/bin/focus-parallels-outlook` for the Karabiner `fn+o` path.

## 2026-05-19 — drag jitter and external-key guard regression

- User-visible regression:
  - Teams/Parallels window dragging became jittery after z-order review changes,
  - logs during the drag showed repeated main-thread `z-order review reason=window-moved-resized` entries every ~200ms while the mouse was down,
  - those reviews scheduled immediate top refreshes plus delayed full z scans, competing with Parallels/WindowServer during live resize/move.
- Fix:
  - record global mouse button down/up,
  - while any mouse button is down, skip `window.updateSpacesAndScreen()`, thumbnail refresh, and z-order review for `windowResizedOrMoved`,
  - remember one pending moved window and run the spaces/thumb/z-order refresh once after mouse-up,
  - change mouse-down from full z review to top-only review to avoid heavy work at drag start.
- Related regression:
  - the first external-keyboard fix fired for normal AltTab modifier events because the modifier event arrived before the global hotkey event,
  - logs showed `released stale z-order enforcement by external keyboard` during ordinary AltTab sequences,
  - fixed by timestamping AltTab shortcut events and delaying external-key release long enough to reject events adjacent to AltTab hotkeys.
- Dev-launch lesson:
  - direct `ai/build.sh dev` background exec launched AltTab but the process exited after the wrapper returned,
  - switched dev launch back to LaunchServices with `launchctl setenv ALTTAB_DYLIB_OVERRIDE` plus `open -na`, preserving TCC and keeping PPID 1 ownership.
- Current state after patch:
  - `bash ai/build.sh compile` passed,
  - `bash ai/build.sh dev` launched PID 96887 through `/Applications/AltTab.app/Contents/MacOS/AltTab`,
  - dev dylib cdhash `482c3b77ccc4f18fd35c38fb7ab5657108e49616`,
  - process stayed alive with PPID 1 and low idle CPU after startup.

## 2026-05-19 — Parallels Desktop coverage and SkyLight native default

- A prior release-gate gap let slow Terminal→Safari runs pass even though the z-sampler recorded first target z0 over one second. `ai/eval-select-transition.sh` now has `MAX_Z0_MS` and fails when `first_target_z0_ms` exceeds the threshold.
- A/B evidence:
  - `original` native mode measured Terminal→Safari at `1293ms`, `1277ms`, and `1464ms`,
  - `hidTitlebarClick` failed source-readiness checks and left Safari top/focused while the evaluator was trying to establish Terminal as the source,
  - `skyLightEventFocus` measured Terminal→Safari at `910ms`, `519ms`, and `444ms` in the A/B run, with no sibling intrusion.
- Current candidate after manual dev relaunch:
  - PID `11575`, dev dylib cdhash `e9773c026c081dc687d5dd5b3ea1c56a6c0f6c34`,
  - `nativeFocusMode=skyLightEventFocus` is now the default after deleting the local override,
  - `focusSelectedWindow` now refuses to arm focus/z-order intent when selection has no `cgWindowId`.
- Targeted validation:
  - `/tmp/alttab-post-skylight-post-skylight-20260519-130227`: Terminal→Safari first z0 `497ms`, `544ms`, `542ms`; Safari→Terminal `472ms`, `348ms`, `530ms`; Terminal↔Parallels Desktop all under `570ms`; bounded log scan had zero failures/warnings.
  - `/tmp/alttab-sameapp-copy-sameapp-copy-20260519-130359`: Terminal→Terminal and Safari→Safari passed 3/3 with zero post-z0 same-app sibling intrusion; Safari toolbar copy passed 3/3.
  - `ai/eval-window-coverage.sh` found the visible Parallels Desktop `Windows 11` console window in AltTab `--detailed-list` and displayable.
- Interpretation:
  - the latest targeted subset is no longer showing nil-target focus, input-capture watchdogs, or all-siblings-up behavior,
  - this is not a release pass; Coherence app matrix, display topology, thumbnail-click/freshness, Spaces, Hammerspoon, drag jitter, and deep/timing matrices remain release blockers in `experiments/release-issue-monitor.md`.

## 2026-05-19 — release monitor expansion from history/code/log review

- Reviewed recent commit history, current diffs, `AGENTS.md`, experiment docs, risky code callsites, and the latest `/tmp/alttab-run.log` tail.
- History added concrete release gates that were not explicit enough:
  - multiple AltTab instances or wrong bundle path from DerivedData/TCC attribution issues,
  - restart/PermissionsWindow cascades from event-tap/TCC failures,
  - stale experimental defaults silently changing runtime behavior,
  - modal/dialog/popup z-order handling from the restored dialog-detection fix,
  - hidden/bugged app windows from upstream hidden-window handling,
  - sleep/wake event-tap recovery,
  - search/filter selection and panel geometry,
  - windowless/app-only `activateAllWindows` boundaries,
  - stuck modifiers and duplicate shortcut fires,
  - compositor pause/overlay-level regressions,
  - capture/pre-capture WindowServer stalls and crash-prone preview paths,
  - eval helper app-launch/app-quit contamination,
  - high-window-count latency,
  - AX observer coverage gaps,
  - private SkyLight/API compatibility,
  - native Command-Tab restoration.
- Recent log tail showed many `app-launched`/`app-quit` z-order review events from helper activity plus one `window-moved-resized-postdrag` review. These did not by themselves prove a current product bug, but they justify explicit eval-contamination and drag-review gates.
- Recent local Codex session logs for 2026-05-19 were narrowly parsed after an overly broad grep hit unrelated repos. The relevant AltTab sessions emphasized rapid-overlap stale events and false passes from missing/restarted bounded markers; those are already represented by REL-008 and REL-050, so no additional row was needed from session review.
- Updated `experiments/release-issue-monitor.md` with REL-054 through REL-071, expanded preflight/build/native/window-lifecycle/keyboard/perf checklists, and added a mandatory history/code-review section.

## 2026-05-19 — release-risk code review and scoped repair hardening

- Created `experiments/release-risk-code-review.md` as the separate code-area risk list mapping release issues to hotspots, risk rationale, validation requirements, and current mitigation status.
- Code review identified the highest-risk implementation issue as broad z-order/AX recovery:
  - full-stack expected z-order restore could move unrelated windows based on a stale preZ snapshot,
  - generic native AX raise fallback could reintroduce same-app sibling promotion,
  - unused native sibling repair helpers were still present even though they were intentionally no longer called.
- Fixes:
  - removed unused native sibling-repair and AX helper functions from `Windows.swift`,
  - narrowed `restoreExpectedZOrder` to only demote same-pid siblings promoted above the first unrelated divider,
  - skipped generic native `kAXRaiseAction` in fast z repair and enforcement; retained AX raise only for Parallels Coherence recovery.
- Added `ai/eval-release-risk-static.sh` to enforce the code-review constraints: no dead sibling repair helpers, no full-stack restore text/path, Parallels-gated AX repair, constrained `activateAllWindows`, doc linkage, and sequential release issue IDs.

## 2026-05-19 — popup-storm regression detection

- Latest broad suite `/tmp/alttab-focus-suite-release-risk-20260519-141048` showed repeated `UserNotificationCenter` frontmost mismatches and stale restores; that run is contaminated and not release evidence.
- Added `ai/eval-popup-storm-guard.sh` backed by a Swift CGWindow query. It counts visible `UserNotificationCenter` windows and exits `86` when the threshold is exceeded.
- Wired the guard into the full focus suite and the direct select/copy/rapid/external eval scripts before risky phases and after samplers, so testing stops immediately when a storm is detected.
- Added log-anomaly failures for popup guard aborts, top-8 `UserNotificationCenter` storm signatures, and frontmost restores against transient `UserNotificationCenter`.
- Product-side guard now ignores transient system frontmost apps in `FRONT_MISMATCH` repair and click-after diagnostics, preventing stale restore attempts against permission/notification UI.

## 2026-05-19 — current popup spam cleared

- User reported visible popup spam. Live guard initially saw no counted `UserNotificationCenter` windows, but `UserNotificationCenter` was frontmost and logs showed `Screen-recording permission call timed out after 6s` every ~7 seconds from AltTab PID 33157.
- Stopped AltTab and killed `UserNotificationCenter`, `usernotificationsd`, `usernoted`, `CoreServicesUIAgent`, and `LocalAuthenticationRemoteService` to clear the visible storm. Guard then reported `ok`, Safari was frontmost, and AltTab stayed stopped.
- Root cause was the Screen Recording permission timer repeatedly invoking the prompt-capable ScreenCaptureKit probe after timeouts. `CGPreflightScreenCaptureAccess()` reported granted, so the prompt-capable probe was unnecessary.
- Fixed `ScreenRecordingPermission.detect()` to use non-prompting `CGPreflightScreenCaptureAccess()` first, delay the initial prompt-capable probe by 5 minutes, throttle normal prompt-capable probes to 5 minutes, and back off 15 minutes after a timeout.
- Validation: `bash ai/build.sh compile` passed; `bash ai/build.sh dev` relaunched AltTab PID 36051 with dev dylib `b757bfb67dd29c8435b038c2193116eb7af14a91`; popup guard stayed `ok` and a 25-second bounded log watch produced no new permission/popup lines.

## 2026-05-19 — panel scrolling resets input-capture watchdog

- User reported the thumbnail viewer disappearing while actively scrolling through pages.
- Recent logs showed the panel disappeared from `[DIAG CAPTURE] watchdog hiding stuck input capture after 15000ms`, not from a normal focus action. The watchdog was armed once at panel open and did not reset on scroll/navigation activity.
- Fix: `App.noteInputCaptureActivity` re-arms the watchdog generation on throttled in-panel activity. It is called from the thumbnail `ScrollView.scrollWheel`, live-scroll start/end, continuous scrollwheel tap, trackpad navigation while the panel is open, handled keyboard/search shortcuts, selection cycling, and mouse movement over the panel.
- Kept the watchdog intact for true idle capture, outside clicks, and stale input passthrough. Mouse movement only resets it when the pointer is over the panel, so ambient pointer drift outside AltTab should not keep capture alive forever.
- Validation: `bash ai/build.sh compile` passed; `bash ai/build.sh dev` relaunched AltTab PID 39967 with dev dylib `b6b37c37c8bb66f9984b2ff96cb3fa80f84b89f8`; popup guard is `ok`.

## 2026-05-19 — outside-click passthrough after panel activity

- User reported clicks on windows like Chrome failing to reach Chrome after the scroll-watchdog fix.
- Root cause: `noteInputCaptureActivity()` rearmed the watchdog by calling `startInputCaptureWatchdog()`, which also reset `inputCaptureStartedAt`. That timestamp is reused by `CursorEvents.handleOutsideUiMouseDown()` to decide whether outside clicks should pass through after `inputCapturePassthroughMs`.
- Fix: split watchdog generation from passthrough age. New panel sessions reset `inputCaptureStartedAt`; scroll/cycle/mouse activity only re-arms the watchdog token and does not make outside clicks “fresh” again.
- Added REL-073 to the release issue monitor. Before release, explicitly open the panel, wait past `inputCapturePassthroughMs`, actively scroll/cycle, then click Chrome/Safari/Terminal and verify `outsideUi-stale→hideUi-pass` plus target-app down/up delivery.
- Validation so far: `bash ai/build.sh compile` passed; `bash ai/build.sh dev` relaunched AltTab PID 42204 with dev dylib `059ab11951a5c4ecd2649858dcd491458fc20235`; popup guard is `ok`. Manual 3x outside-click validation still required.

## 2026-05-19 — thumbnail-click latency, Cmd+` collision, ghost cycling, minimized focus

- User reported thumbnail-click focus was very slow. Recent logs showed mouse-click selection itself was immediate, but `Window.focus()` spent 0.6-1.7s in the synthetic `skyLightClickFocus` path for several native targets. The live default had become `nativeFocusMode=skyLightEventFocus`; reverting the default to `original` removes that synthetic click from normal Mac↔Mac/thumbnail focus.
- User reported Chrome-front Cmd+` brought Edge Beta/another app. Recent logs showed `nextWindowShortcut2` global hotkey events during Cmd+` usage. This is a real shortcut collision: the second AltTab shortcut was Command+key-above-Tab, which steals the native macOS per-app window cycle. Added REL-074 and protected Command+grave / Command+Shift+grave registration by default.
- Correction: the user's actual shortcut preferences intentionally assign Cmd as the hold modifier and key-above-tab as the second AltTab next-window key. Default-on protection suppresses that configured shortcut and prevents the thumbnail gallery from opening. REL-078 tracks this; `protectNativeCommandBacktickShortcut` must be opt-in only, and release validation must test both modes instead of assuming native Cmd+` always wins.
- `ai/eval-cmd-backtick-gallery.sh` initially found 1/3 passes. Logs showed `nextWindowShortcut2 down/up` was registered, but `focusTarget` sometimes fired on the key-above-tab up before Cmd was released and before `showPanel`. Cause: `ATShortcut.redundantSafetyMeasures()` trusted `NSEvent.modifierFlags` at the global hotkey-up boundary; for Cmd+` it can read as released even though recent `flagsChanged` showed Cmd still down. Fix: cache recent modifier flags in `KeyboardEventsTestable` and suppress redundant hold-release while the hold modifier is observed down.
- User reported the thumbnail viewer can rapidly cycle while only Cmd is held. Logs showed repeated `nextWindowShortcut down/up` pairs while the panel remained open. Artificial repeat should only be needed for modifier-only shortcuts; for real key-coded Tab/` shortcuts the OS key repeat already provides repeats. Disabled `KeyRepeatTimer.startRepeatingKeyNextWindow()` for key-coded shortcuts and added REL-075.
- User reported minimized Messages did not foreground from AltTab. Added pre-focus deminimize handling for minimized windows and refreshes a missing `cgWindowId` from AX before the nil-target guard. Added REL-076 for minimized hotkey and thumbnail-click validation.
- Validation so far: `bash ai/build.sh compile` passed after these code changes. A dev relaunch and 3x live checks are still required.

## 2026-05-19 — gallery icon-only thumbnails

- User reported the gallery sometimes shows only app icons and thumbnails stay icons without refreshing.
- Existing `--selection-state` / `--detailed-list` already expose `hasThumbnail`, `thumbnailAgeMs`, and `thumbnailUpdateCount`, so the right regression check is to open the gallery, wait for capture, query selection state, and fail on displayable non-minimized windows that remain missing/stale.
- Added REL-077 and `ai/eval-thumbnail-coverage.sh`. This checks normal thumbnail coverage and prints missing/stale rows; it does not yet prove content-change freshness, which remains under REL-020.
- Thumbnail eval first checked the top list slice and failed on stale deeper Safari windows while the live UI had scrolled to a different visible page. That was a test bug and a product observability gap. `--selection-state` now includes `visibleThumbnailWindowIds`, and `ai/eval-thumbnail-coverage.sh` validates the actual visible UI slice by default.
- User reported that clicks on one screen do not reach apps when a window exists on another screen. Current `CursorEvents` passed stale outside mouse-down through but always swallowed the matching outside mouse-up. On some apps/monitor transitions, a down-only click is not enough to activate/focus. REL-080 tracks multi-monitor outside-click routing. Fix: remember when stale outside mouse-down was passed and pass the matching outside mouse-up as `outsideUi-after-pass`.
- `ai/eval-multiscreen-click-routing.sh` confirms this machine has two screens (`2304x1296` and `2056x1329` with negative-y origin). After the pass-through patch, it still needs a deliberate cross-screen outside click to produce the expected CTAP log pair; absence of that log is now a failing, not passing, condition.
- Window coverage false failure: WindowServer reported two `Parallels Desktop / Windows 11` windows (`148779`, `143505`) while AltTab correctly marked one older/off-Space VM proxy as `notInVisibleSpace` and the visible console window title had changed to `"Windows 11" Configuration`. `ai/eval-window-coverage.sh` now filters candidate WindowServer rows through AltTab `isDisplayable` by default so it catches missing displayable windows instead of intentionally hidden off-Space proxies.

## 2026-05-19 — thumbnail capture route and latest bounded validation

- Root cause for the icon-only gallery state was not just stale cache selection. Recent logs had repeated ScreenCaptureKit one-time capture failures: `SCStreamErrorDomain Code=-3802 "Stream failed to start"`. On this OS/build, SCK is not a reliable default capture path for gallery thumbnails.
- Fix: `thumbnailUseScreenCaptureKit` now defaults false and `Windows.refreshThumbnailsAsync` routes native windows through the private WindowServer capture path unless SCK is explicitly enabled. Parallels Coherence remains private capture regardless because SCK cannot see guest-composited pixels.
- `ai/eval-thumbnail-coverage.sh` now writes its own eval marker and runs `ai/eval-log-anomalies.py` over that marked window. Any `SCStreamErrorDomain` or `Code=-3802` inside the thumbnail eval fails the run instead of being found only by manual log review.
- Validation on dev dylib `a7eb5d82e1c21cd9748b7c04305116469d1ff675`, AltTab PID `62367`: `bash ai/build.sh compile` passed; `bash ai/build.sh dev` restarted cleanly; `ai/eval-thumbnail-coverage.sh` passed with `visible_ids=37`, `fresh=37`, `ratio=1.00`, and marked log scan `failures=0 warnings=0`; `ai/eval-window-coverage.sh` passed for the Parallels Desktop `Windows 11` displayable window; `ALLOW_SYNTHETIC_HOTKEY_TESTS=1 ai/eval-cmd-backtick-gallery.sh` passed; popup storm guard was `ok`.
- Remaining gap: `ai/eval-multiscreen-click-routing.sh` correctly detects two screens but still needs a deliberate stale outside cross-screen click to produce and validate the `outsideUi-stale→hideUi-pass` / `outsideUi-after-pass` CTAP pair.

## 2026-05-19 — Cmd+N new Terminal window behind current window

- User reported `Cmd+N` in Terminal created a new Terminal window behind the current Terminal window.
- Recent logs showed the relevant pattern: AltTab had a stale same-pid z-order intent for an older Terminal target, then Terminal emitted `created-window wid=149690` without a matching immediate focus update. This allowed stale enforcement/recency state to fight or mis-rank the newly-created same-app window.
- Added REL-082 to the release monitor. The release check must distinguish app window-creation latency from AltTab z-order correctness: once WindowServer first reports the new window, it should already be visual z0 and remain there.
- Fix: on both app-level and window-level `kAXWindowCreatedNotification`, release stale z-order enforcement when the created window belongs to the same pid as the last AltTab z-order intent but has a different wid. Also schedule a short live-frontmost sync after active-app creation so AltTab recency catches the new window even when AX focused-window notification is missing/late.
- Added `ai/eval-created-window-front.sh`, which focuses a source window, posts `Cmd+N`, samples high-resolution z-order, detects the new wid, validates it reaches z0 immediately after first appearance, scans the marked log window, and optionally closes the test window.
- Validation on dev dylib `34cec3a218a2b3e4b3fc9aa246c934ac471e98ef`, AltTab PID `95157`: `bash ai/build.sh compile` passed; `bash ai/build.sh dev` restarted cleanly; `CLOSE_NEW=1 APP_REGEX=Terminal bash ai/eval-created-window-front.sh` passed 3/3. New Terminal windows first appeared at 1223ms/678ms/1061ms and were z0 immediately on first appearance (`z0_after_seen_ms=0.0` each), stayed top, and had zero marked log failures. Thumbnail coverage and Parallels window coverage smoke checks also passed after the change.

## 2026-05-19 — delayed OneNote flash after switching to Terminal

- User reported OneNote flashed unnecessarily about 1-2 seconds after switching to Terminal.
- Log evidence showed a Parallels→Terminal switch followed by stale guard release from a modifier-only event: `released stale z-order enforcement by external activation ... pid=96334 target=#123883 key=modifiers=256 keyAge=29ms`. That event is just the AltTab/Cmd modifier boundary, not affirmative user intent to abandon the Terminal target.
- A second broad path released z-order enforcement on app-level `kAXWindowCreatedNotification` for Parallels pids without a concrete new window id. Parallels Coherence emits app-created lifecycle noise during normal focus settling, so treating that as a real new window can prematurely drop the target guard.
- Fix: external keyboard input now records whether it is allowed to release z-order. Modifier-only events that are just configured AltTab shortcut/hold modifiers update the timestamp/label but cannot clear the guard; modifier-only events with other modifiers remain available for external focus workflows. Parallels app-level created-window notifications no longer release z-order enforcement unless a concrete window-level creation path identifies a new wid.
- Added REL-083. Required validation is Parallels→Mac 3x with bounded log scan proving no AltTab-shortcut `key=modifiers=` guard release, no post-z0 source reappear, and a non-AltTab external-hotkey rerun proving intentional external activation still cancels stale guards.
- Validation on live dev dylib `a036c2662b421dd1545a07ccb784737c049a62ef`: one clean OneNote→Terminal rep reached target z0 at `448.2ms`, had zero post-z0 source reappears/flicker/sibling intrusions, and the bounded log scan had no failures. Attempts to continue 3x validation stopped because `ai/eval-user-idle-guard.sh` detected active user input, preventing another contaminated pass.
- Added `ai/eval-user-idle-guard.sh` and wired it into UI-driving evals. This addresses the immediate testing failure where a real mouse drag/click during the bounded run made the z-sampler evidence good but the log scan correctly failed for mouse contamination.

## 2026-05-19 — Parallels OneNote thumbnail-click handoff and Karabiner readiness

- User report: AltTab thumbnail click to Parallels OneNote, then `fn+e`, did not open OneNote search until manually clicking the OneNote window. The same path also felt very slow.
- Evidence from `/tmp/alttab-run.log`:
  - `18:53:49.224` and `18:54:56.538` selected OneNote `wid=149427` via `[mouseClick]` and entered `atomicallyPinAndActivate`.
  - Immediate macOS-side calls completed in `47-131ms`, and async AX focus finished in about `62ms`, but `parHideNow` fired after `1203-1360ms` with `ready=false`, `front=true`, and `top` still Safari/Terminal.
  - Several seconds later `FRONT_MISMATCH` restored OneNote via `SLPS(noWin)+makeKey`; after a manual OneNote click the Karabiner `fn+e` mapping worked.
  - The log also captured `CLICKMISROUTE` / `CLICKAFTER` against Safari while AltTab still believed OneNote owned keyboard focus, confirming split visual/frontmost state after the panel hid.
- Cause: for Parallels targets, `frontPid == targetPid` is not enough. Hiding the AltTab panel on the max-delay timeout exposes a stale visual top window and leaves Parallels guest keyboard readiness unsettled. The later z-order repair is too late for immediate Karabiner hotkeys.
- Fix candidate: `scheduleParHideUi` now gives Parallels targets a hard safety max, but starts bounded `PARHIDE` reassertions after `parTargetReassertDelayMs` while the panel is still up. The panel hides only when the target is visual z0, stable, and frontmost, or at the hard max. The default reassert delay is `350ms`, hard max `3000ms`.
- Release tracking: added `REL-084` for Parallels target visual/keyboard readiness after AltTab and thumbnail clicks.

## 2026-05-19 — Safari same-app sibling block after native focus

- User reported Safari windows were again all at the front of z-order. I immediately stopped the live AltTab dev process to prevent more focus/z mutation.
- Current z-sampler after stopping AltTab showed Terminal at z0, followed by a large contiguous Safari block. Logs around `19:01-19:02` showed Safari window focus and same-app cycling while the native focus path used `SLPS(userGenerated)+makeKeyWindow`, which is exactly the path known to promote sibling windows in multi-window apps when not repaired.
- Code review found the likely regression: earlier direct native sibling repair hooks had been removed and replaced by delayed enforcement. That delayed path depends on cached/stale `preZ` and can miss the exact pre-focus order; if it misses, it cannot demote Safari siblings back under the prior foreground window.
- Fix candidate: native focus now captures a fresh live pre-focus z snapshot at focus time instead of falling back to a stale full cache, and `armNativeFocusZOrderIntent` immediately schedules bounded expected-z-order repairs at `0/80/180/360/700ms`. The repair remains narrow: it only demotes same-pid siblings that were promoted above the first expected non-target divider; it does not use app-level activation or broad full-stack AX raises.

## 2026-05-20 — external foreground ownership after AltTab

- User reproduced a stale restore by using a Karabiner hotkey to bring Parallels OneNote forward after an AltTab switch. Recent logs showed AltTab still had a prior target intent and restored the old target on `FRONT_MISMATCH`.
- Root cause: the guard release logic was keyboard/activation-specific instead of foreground-owner-specific. External focus can arrive through Karabiner, manual activation, AX focused-window/main-window notifications, NSWorkspace activation, or simply as a settled foreign z0/front app.
- Fix: added `releaseZOrderEnforcementForExternalForegroundOwner`, used by AX app activation, AX focused/main-window changes, NSWorkspace activation, focus invariant repair, fast z monitor, and frontmost mismatch repair. It releases stale AltTab intent on credible external ownership evidence before any restore/counter-raise.
- Release coverage: updated REL-088 and release-risk notes. Required proof is 3x Karabiner/manual external focus inside the post-AltTab guard window, plus a no-key negative control and bounded log scan for no `FRONT_MISMATCH ... restoring` after the external owner appears.
- Validation so far: `bash ai/build.sh compile` passed. Dev relaunch and live REL-088 eval remain required after this patch.

## 2026-05-20 — minimized windows default to end for all shortcut profiles

- User reported minimized windows were still not at the end and specifically called out Alt+`.
- Existing product setting is `Show minimized windows` with values `Show`, `Hide`, and `Show at the end`. The primary profile already had the persisted value `2`, but `showMinimizedWindows2` was unset, so the second shortcut profile inherited the old code default `Show` and could intermix minimized windows.
- Fix: changed the default for `showMinimizedWindows*` to `showAtTheEnd` for every shortcut/gesture profile. This makes normal Alt-Tab and Alt+` share the same minimized-window suffix behavior unless the user explicitly changes the setting.
- Added `ai/eval-minimized-order.sh` to open profiles `0` and `1`, query `--selection-state`, and fail if any displayable minimized window appears before a displayable non-minimized window.

## 2026-05-20 — fn+l OneNote source-window reactivation flicker

- User reported flashing when using Karabiner `fn+l` to bring Parallels OneNote forward.
- Logs at `2026-05-20 17:30:30-17:30:32` showed AltTab had just switched from OneNote `#149427` to Terminal `#130253`. `fn+l` generated modifier-only events, OneNote became frontmost/z0, then AltTab treated this as stale source reactivation and restored Terminal (`FRONT_MISMATCH ... restoring`), followed by invariant repair. That restore caused the visible flash.
- Cause: external foreground-owner release required a “releasable” keyboard event for cross-pid foreground changes, and excluded settled source reappearance. Karabiner can consume the actual key and leave AltTab seeing only fn/hyper modifier transitions, so the external intent was real but not classified as releasable.
- Fix: once another pid becomes foreground after an AltTab target and the keyboard event is not temporally AltTab's own shortcut, any recent external keyboard event is enough foreground-ownership evidence. This applies even when the new owner is the previous source window.

## 2026-05-20 — fn+l/fn+o OneNote↔Outlook flicker after AltTab handoff

- Evidence from `/tmp/alttab-run.log` around `17:35:14-17:35:29`:
  - AltTab switched `OneNote #149427` / `Outlook #149437` to Terminal `#130253`, then external Karabiner-style modifier-only hotkeys (`modifiers=8388864`, `524576`, `131330`, then `256`) alternated OneNote/Outlook.
  - A stale AltTab target event arrived after external ownership: `app-activated wid=130253` at `17:35:15.297`, after OneNote had already been reactivated by keyboard input.
  - External hotkey transitions also produced repeated `app-activated` + `focused-window` full z-order reviews and `app-launched`/`app-quit` lifecycle reviews roughly 400-650ms after each Parallels foreground change.
- Causal model:
  - When a non-AltTab focus mechanism takes over soon after an AltTab Parallels handoff, AltTab must cancel its active handoff state, invalidate the AltTab source/target pair even if the panel is still active, and ignore stale target AX events unless the target is still truly frontmost/z0.
  - External app focus should update only the top z cache immediately; full z refreshes during rapid OneNote↔Outlook hotkey alternation add avoidable WindowServer/AX churn and make log causality harder to read.
- Fix candidate:
  - `App.noteDirectFocusOutsideAltTab` now cancels pending Parallels hide/capture state and hides any active panel before invalidating the AltTab pair.
  - `App.shouldSuppressStaleAltTabTargetEvent` drops delayed AX target events after external keyboard ownership when the target is no longer frontmost or z0.
  - `AccessibilityEvents` uses top-only z reviews for external focus events outside an active/recent non-invalidated AltTab handoff.
  - `RunningApplicationsEvents` now derives actual KVO launch/quit deltas using `kind`/`indexes` or pid diff, and uses top-only z review for non-regular process churn.
- Validation signal:
  - After an `fn+l`/`fn+o` run, logs should show no stale target `app-activated wid=<previous AltTab target>` updating recency after external ownership, fewer full `z-order review reason=app-activated/focused-window` lines during external hotkey alternation, no `FRONT_MISMATCH`, no `COUNTER`, and no `ANOMALY`.

## 2026-05-20 — 1.2.1 residual fn+l/fn+o flicker/racing

- Evidence after `1.2.0` looked materially better: no `FRONT_MISMATCH`, no `COUNTER`, no `ANOMALY`, and stale target events were gone.
- Remaining visible flicker correlated with dense event churn during rapid Parallels OneNote/Outlook hotkeys:
  - every hotkey produced `NSWorkspaceDidActivateApplicationNotification`, `app-activated`, `focused-window`, and often `app-launched`/`app-quit` top z reviews;
  - a few Parallels transient window-created events still triggered full `z-order review reason=created-app` scans during the burst.
- Fix candidate for `1.2.1`:
  - coalesce top-only z reviews on the main thread with a short 60ms flush window, keeping only the latest wid/reason and one delayed top refresh;
  - keep normal full reviews for AltTab focus intents and non-Parallels real lifecycle events;
  - downgrade Parallels `kAXWindowCreatedNotification` review work to top-only (`created-app-parallels`) because those events are often transient Coherence helper/window churn during guest foreground changes.
- Validation signal: `fn+l`/`fn+o` bursts should show `z-order top review flush` lines instead of dozens of immediate top cache refreshes, no full `created-app` reviews for Parallels, and still no focus/z anomaly markers.
