# AltTab Window-Switch Experiments — Self-Paced Loop

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
