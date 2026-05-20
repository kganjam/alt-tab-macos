# AltTab Focus / Z-Order Hypotheses

Living decision log for the current AltTab performance/correctness work. Keep this updated whenever a hypothesis is tested, disproven, or promoted into a design constraint.

## Current Claims

| Claim | Status | Evidence | Decision |
|---|---|---|---|
| UI/focus measurements need at least 3 clean repetitions. | Standing rule | User activity can overlap unattended runs, and real clicks/typing/display changes can look like focus/z-order regressions in samplers and logs. Single samples already produced contaminated observations during this work. | Run each validation at least 3 times when feasible; mark runs with user activity or external app/display events as contaminated and rerun before drawing conclusions. |
| Focus/z-order log scans must be bounded by start and end markers. | Standing rule | Rapid-overlap run `rapid-overlap-20260519-025812-10827` wrote its marker before the logged AltTab process restarted. The old scanner used marker-to-EOF and reported `lines=0 failures=0`, while the sampler showed the final target never reached z0. | Use `--end-marker`, fail missing end markers, fail restarts after markers, and persist z-scan output beside log-scan output. |
| Automatic stuck-permission-popup flushing must be opt-in only. | Standing rule | Live dev PID 11168 logged `stuck-popup detection` every 10s, killing UserNotificationCenter/usernotificationsd and spamming permission dialogs. | Default `flushStuckAuthPopupsThreshold` to `0`; treat any stuck-popup flush log as a failed/contaminated run. |
| Synthetic hotkey tests are unsafe on the live Terminal session. | Standing rule | A hotkey-path probe switched back to Terminal while the user observed keystrokes being routed to the Terminal session. Even if the helper intends to post only modifier/tab events, global hotkeys are real input and can leak into the active app if AltTab/system handling differs from expectations. | Do not run global-hotkey probes against the user's active Terminal. Require explicit opt-in flags and an isolated test desktop/window. Prefer exact-focus and noninteractive samplers unless the user explicitly approves live hotkey input. |
| Safari same-app switching is fast; cross-app Safari switching is slow. | Supported | User observation; CLI probes showed Safari window-to-window feels fast, while Terminal→Safari and Activity Monitor→Safari leave Safari frontmost in the menubar but not z0 for ~750-1500ms. | Treat Safari delay as cross-app WindowServer/z-order handoff, not Safari tab/window selection. |
| Native Mac↔Mac focus is not blocked on AltTab queue contention. | Supported | `AXFOCUS queue` usually ~0.0-0.1ms; panel refresh logs around ~1ms; logging overhead around ~70us average. | Do not spend more time on locks/main-thread z-cache unless new evidence shows queue wait or refresh spikes. |
| Instruments attach profiling is useful; all-process `xctrace` is not safe unattended here. | Supported | `xctrace record --template 'Time Profiler' --attach <AltTab pid>` captured clean data while CLI panel switches ran. `--all-processes` exceeded its 14s limit and had to be killed, likely due Instruments privilege/collection behavior. | Use attach traces for AltTab CPU/main-thread evidence. Avoid unattended all-process Instruments unless manually supervised. |
| `CGSOrderWindow` is not a valid cross-process native-window fast path. | Supported | Native path call returned `cgsErr=1000`; web research also reports error 1000 when a process tries to order another app's window. It sometimes added tens of ms. | Do not put `CGSOrderWindow(..., above, 0)` in normal native Mac↔Mac focus. |
| App-level activation/frontmost APIs can violate AltTab's per-window invariant. | Supported | `kAXFrontmost=true` experiment eventually raised many Safari windows; system app-level activation also raises app groups. AGENTS says this is a hard regression. | Do not use `NSRunningApplication.activate(.activateAllWindows)` or app-level `kAXFrontmost` for standard native focus. Restrict app-level frontmost recovery to Parallels-only cases. |
| `CGSSetWindowLevel`/temporary level pin is not a reliable fix for Safari z-order delay. | Supported | Level pin returned success but did not make Safari z0 immediately; visible delay stayed hundreds of ms. | Do not rely on cross-process level pin for native Safari/Terminal switching. |
| Safari delay is not Terminal-specific. | Supported | Activity Monitor→Safari reproduced the same “frontmost app changed, window remained behind” pattern. | Avoid Terminal-only special cases for this bug. |
| Raising Safari process priority via `renice -2` is unlikely to help. | Supported | Delays occur after frontmost changes and after fast AX/SLPS phases; bottleneck is WindowServer/SkyLight/AX ordering, not Safari renderer CPU. | Do not add process-priority hacks. |
| CLI `--focus` is useful for exact-window tests but does not fully match panel-driven AltTab switching. | Supported | CLI calls `window.focus()` directly and bypasses panel selection/hide logic; synthetic global hotkeys are unsafe and unreliable on the live Terminal session. | Use CLI for isolated focus timings; use `ai/eval-switch-transition.sh` for live panel-path validation without global keystrokes. |
| Shift is the safest live keyboard focus probe. | Supported | `ai/post-shift-probe.swift` posts Shift down/up only; recent Terminal↔Safari and sacrificial-window runs produced focus-delivery evidence without inserting text or sending Enter/Tab into Terminal. | Use `SHIFT_PROBE=1` for live focus tests; avoid printable keys and Enter/Tab in the user's active environment. |
| Test probes can perturb Terminal z-order if they print while measuring. | Supported | Early probe printed to Terminal during switch and could change visible ordering. Buffered-output probe reduced this artifact. | Synthetic probes should buffer samples and print only after the measurement window. |
| Heavy diagnostics, thumbnail capture, and z-cache/z-fix work are not the root cause of Terminal→Safari delay. | Supported | Low-overhead profile (`diagnosticsBasicPerfOnly=true`, thumbnails off, overlay capture off, z-cache off, z-fixes off) still measured Terminal→Safari at ~750-1000ms by exact focus and ~1030-1630ms by hotkey external z sampling. | Keep the toggles for A/B testing, but pursue Safari/WindowServer handoff behavior rather than logging/thumbnail/z-cache contention. |
| Plain app activation is faster than per-window focus for Safari but violates AltTab semantics. | Supported | `tell application "Safari" to activate` reached Safari z0 in ~626-745ms with the external sampler, faster than AltTab hotkey but still not instant and app-level activation can raise sibling windows. | Do not use app-level activation in standard window focus; it is diagnostic evidence only. |
| Native SLPS/AX mode changes do not solve Safari z delay. | Supported | Three reps each for `userGeneratedFocus`, `noWindowsFocus`, `noWindowsRaise`, and `userGeneratedRaise` all left Terminal→Safari around ~750-1000ms exact-focus z0. | Do not use these as defaults for native Mac↔Mac; they remain rollback/diagnostic modes only. |
| The original upstream AltTab focus body is not a hidden fast path. | Supported | `nativeFocusMode=originalAltTab` ran the upstream body on `accessibilityCommandsQueue`: `SLPS(userGenerated) → makeKeyWindow → AX focusWindow → 50ms preview`. Terminal→Safari first visible z0 was 1000, 750, 750, 500, 1250, 750ms; Safari→Terminal was 200, 300, 200, 200, 200, 200ms. | Stop treating upstream rollback as an unexplored fix. Preserve the upstream semantics, but pursue the WindowServer/user-click path difference. |
| A real WindowServer titlebar click activates Safari much faster than SLPS/AX. | Supported | Strict source-validated Terminal→Safari titlebar click runs: first pass 63.6, 84.5, 75.3, 87.5, 81.6, 68.1ms; rerun 79.0, 68.2, 81.4, 78.5, 88.5, 82.5ms. | Investigate a safe non-user-visible equivalent. Do not ship raw cursor-moving clicks by default without guarding against pointer jumps, panel obstruction, wrong-window clicks, and titlebar coverage. |
| Targeted `SLEventPostToPid` is the best current standard native focus path. | Supported | 2026-05-18 matrix: `originalAltTab` Safari focus was ~530-1100ms and one Safari copy probe failed at 0.8s. 2026-05-19 A/B measured `original` Terminal→Safari at `1293/1277/1464ms`, while `skyLightEventFocus` measured `910/519/444ms`; final targeted run measured Terminal↔Safari and Terminal↔Parallels Desktop under `570ms` with no sibling intrusion/log failures. | Default native focus to `skyLightEventFocus`; keep unsafe modes behind `nativeExperimentalFocusModesEnabled`; keep no-windows Terminal/iTerm path as opt-in rollback only. |
| Terminal/iTerm SkyLight focus must be same-app regression tested. | Supported | Earlier experiments brought all Terminal windows forward. After removing native sibling AX repair and validating the SkyLight path, Terminal→Terminal passed 3/3 with `same_app_above_after_z0_max=0` and no sibling intrusion. | Allow default SkyLight for Terminal/iTerm only while same-app z-sampler checks pass; never use app-level activation or sibling AX repair for Terminal/iTerm. |
| Safari startup/restart is not what raises Safari windows. | Supported | `ai/eval-restart-zorder.sh Safari` before/after restart showed identical top order and no top changes; watched Safari stayed z1 with the same Safari count in top16. | Treat apparent restart clustering as existing z-order/focus-mode pollution, not launch-time activation. |
| Copy/paste regression is catchable with a focused keyboard smoke test. | Supported | `ai/eval-copy-after-focus.sh Safari` focuses the target, posts exact `Cmd-L`/`Cmd-C` via CGEvent, and asserts pasteboard equals Safari's current URL. It reproduced a failure when `originalAltTab` had not made Safari key by 0.8s. | Run this probe after focus-path changes; release known synthetic modifiers before/after key tests. |
| Synthetic focus clicks must not look like user clicks to AltTab. | Supported | After enabling native z enforcement, `SLEventPostToPid` focus clicks were observed by AltTab's global mouse monitor at the stationary cursor position, resolving to Terminal and canceling the z-order intent. This produced a false Terminal-over-Safari flicker and copy failure. | Mark synthetic focus clicks and ignore matching short-window global mouse events before updating `lastMouseClickTime` or releasing z enforcement. |
| Native focus needs short-lived z enforcement even without input-capture guard. | Supported | The evaluator caught late Safari sibling overtakes (~+1.17s) and Terminal sibling overtakes (~+0.31s). Adding native z-intents with pre-focus z snapshots fixed final two-cycle validation: Safari first z0 ~80-129ms, copy passed, Terminal first z0 ~159-188ms, no post-z0 flicker or sibling intrusion. | Use `armNativeFocusZOrderIntent` for SkyLight native focus and Terminal/iTerm target-only focus; do not set `altTabFocusTarget` for this path. |
| `CGPostMouseEvent(... updateMouseCursorPosition=false ...)` gives the fast click path without moving the cursor. | Supported | Runtime dlsym of the SDK-unavailable symbol succeeded. Probe from cursor 640,640 clicked Safari titlebar at 178,57, returned success, left cursor at 640,640, and made Safari z0. Integrated guarded fallback with exposed-point validation; final Terminal↔Safari matrices with a 60ms fallback had no misses and worst direct z0 ~197ms / hotkey z0 ~278ms, versus prior 750-1600ms outliers. | Keep as guarded rollback/diagnostic mode. Current default uses targeted `SLEventPostToPid`, which avoids global cursor routing and was faster in the latest Safari copy/z-order matrix. |
| Thumbnail capture must be hard-blocked during Parallels focus settle. | Supported | Live logs at `2026-05-20 12:21:37` showed a Par→Mac focus had finished host focus and scheduled `parHideScheduled`, then `keyboard hiding stale input capture after 3000ms` hid the panel before `parHideNow`; earlier panel-open logs also showed visible thumbnail refreshes overlapping Coherence handoff. Winside was reachable, and guest foreground/list mismatch confirmed a parallel Windows-side state race. | Use a lock-backed thumbnail capture gate from target selection until Parallels hide/settle completes; queued screenshot workers must re-check the gate before capture and before applying thumbnails. Do not merely reduce capture rate. |
| Main-thread diagnostic AX probes can create artificial focus latency. | Supported | `sample` during hotkey stress found the main thread spending ~1.3s/25s in the +200ms CLICKAFTER AX focused-window probe. Moving the AX lookup behind the mismatch check and off-main removed that sampled main-thread AX path. | Never put AX diagnostics on the main thread; first prove a mismatch cheaply, then do AX work on a background queue. |
| A stuck input-capture session can make the desktop appear frozen. | Supported | The recovered foreground log stream for PID 34492 kept processing refresh events until SIGTERM at 11:40, but there were no global mouse-down logs while the user was unable to click other apps. Global NSEvent monitors only see clicks not swallowed by AltTab's CGEvent tap, so this points to `CursorEvents` remaining enabled while `App.appIsBeingUsed` stayed true. | Input capture must fail closed: outside mouse-down hides immediately, stale capture lets the click pass through, duplicate focus release hides UI, and a watchdog hides any session that outlives `inputCaptureWatchdogMs`. |
| Par↔Mac must hide the switcher only after the target is visibly topmost. | Supported | User reported flashing persisted after restoring a fixed 200ms cross-boundary curtain. External 10ms WindowServer sampler showed top-window handoff could occur ~490ms after the hotkey, so a fixed 200ms hide still exposed the old window. After changing Par hide to poll `topVisibleAppWindowId`, six sampled Par↔Mac reps had one-step top-window transitions and all matching logs hid with `parHideNow ... ready=true`. | Par-involved hide is readiness-gated: wait at least the configured min delay, then hide only when target is top visible app window or `parHideMaxDelayMs` expires. |

## Evidence Log

### 2026-05-18 — Three-clean-run validation rule

- Added the validation rule to `AGENTS.md`: UI/focus/z-order checks need at least three clean repetitions.
- The rule immediately caught a contaminated copy run: Safari reached z0, then a global mouse-down on Terminal 1359ms after focus moved frontmost input to Terminal. Isolated copy probes then passed 5/5, so the failed sample was not used as evidence of a focus regression.
- Final clean three-pass matrix after relaunch:
  - Safari z0: 78.2, 67.1, 65.0ms.
  - Safari copy: 3/3 passed at `DELAY=1.2`.
  - Terminal z0: 219.2, 161.9, 224.1ms.
  - No post-z0 flicker or sibling intrusion in any of the six focus samples.
- The copy helper now releases modifier keys before Tab so the cleanup step cannot synthesize `Option+Tab` and trigger `nextWindowShortcut`.

### 2026-05-18 — Native path `CGSOrderWindow` experiment

- Added target-only `CGSOrderWindow(CGS_CONNECTION, targetWid, .above, 0)` after `_SLPSSetFrontProcessWithOptions`.
- Exact-window Terminal↔Safari run: every `CGSOrderWindow` returned `1000`; `cgs` phase sometimes cost up to ~52ms.
- No `SAMEAPP`, `FRONT_MISMATCH`, or `CLICKMISROUTE` occurred, but the call was ineffective and added latency.
- Result: remove from normal native Mac↔Mac focus.

### 2026-05-18 — Upstream-style async native path

- Restored the upstream ordering for native focus: background queue runs `SLPS(userGenerated) → makeKeyWindow → AXRaise`.
- Kept failed-CGS removal and timing diagnostics.
- Typical `AXFOCUS` after buffering:
  - Terminal target: ~31-69ms end-to-end.
  - Safari target: ~73ms API end-to-end while visible z0 arrived much later.
- Result: focus API path is reasonably fast; visible delay is downstream of the focus RPC.

### 2026-05-18 — Visible z-order probes

- Buffered probe samples `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` at fixed offsets.
- Terminal→Safari:
  - `front=Safari` appears almost immediately.
  - `AXFOCUS` finishes around ~73ms in representative runs.
  - `top=Safari` did not appear until ~1000-1500ms.
- Activity Monitor→Safari reproduced similar behavior, proving the issue is not Terminal-specific.
- Result: problem is cross-app Safari z-order/compositor handoff.

### 2026-05-18 — AX frontmost/main/focused setters

- Added `kAXFrontmost=true`, `kAXFocusedWindow`, `kAXMain=true`, and `kAXFocused=true` around existing per-window AX raise.
- Safari eventually raised many Safari windows together.
- This violates “selected window only” behavior.
- Result: revert for standard native focus; do not repeat.

### 2026-05-18 — Temporary window level pin

- Tried `CGSSetWindowLevel(targetWid, CGWindow.floatingWindow)` then restore.
- API returned success, but Safari did not become z0 immediately.
- Result: not a valid fix for this case.

### 2026-05-18 — Low-overhead profile and native focus mode A/B

- Added runtime flags:
  - `diagnosticsBasicPerfOnly`
  - `thumbnailCaptureEnabled`
  - `focusOverlayCaptureEnabled`
  - `zOrderCacheEnabled`
  - `zOrderFixesEnabled`
  - `nativeFocusMode`
- Low-overhead exact-window matrix with diagnostics limited to basic perf, thumbnails/overlay capture off, z-cache off, and z-fixes off:
  - Terminal→Safari: 1000, 750, 750ms.
  - Safari→Terminal: 150, 200, 300ms.
  - Safari→Safari: 150, 200, 200ms.
  - Terminal→Terminal: 100, 100, 100ms.
  - Safari→Activity: still >2000ms in all three reps.
- Low-overhead hotkey external z sampler:
  - Terminal→Safari: ~1629, 1130, 1034ms.
  - Safari→Terminal: ~186, 189, 225ms.
  - AltTab internal focus API still completed quickly: Safari `AXFOCUS` typically ~80-130ms.
- Re-enabled z-cache/z-fixes while thumbnails stayed off:
  - Terminal→Safari: 1000, 750, 750ms.
  - Safari→Terminal: 200, 200, 150ms.
  - Conclusion: native z-cache/z-fix work is not materially changing this path because native focus still does not arm active `ZENFORCE`.
- `nativeMultiWindowAxTimeoutMs=1000` made Safari AX calls block ~700-800ms but still left visible z0 around ~1000ms.
- `nativeFocusMode` A/B, three reps each:
  - `userGeneratedFocus`: Terminal→Safari 1000, 750, 1000ms.
  - `noWindowsFocus`: Terminal→Safari 1000, 1000, 1000ms.
  - `noWindowsRaise`: Terminal→Safari 1000, 1000, 750ms.
  - `userGeneratedRaise`: Terminal→Safari 1000, 1000, 750ms.
- Plain app-level activation (`tell application "Safari" to activate`) reached Safari z0 around ~626-745ms but can raise app siblings, so it is not acceptable as AltTab's standard path.

### 2026-05-18 — Real titlebar click simulation

- Built a buffered click probe that:
  - focuses Terminal source first,
  - finds an exposed point in Safari's titlebar,
  - posts HID mouse move/down/up,
  - samples z-order without printing during the measurement window.
- Strict Terminal→Safari click test, six valid reps:
  - 63.6, 84.5, 75.3, 87.5, 81.6, 68.1ms.
- Immediate rerun, six valid reps:
  - 79.0, 68.2, 81.4, 78.5, 88.5, 82.5ms.
- This is much faster than AltTab's `SLPS(userGenerated) → makeKeyWindow → AX focus/raise` path, which stays around ~750-1000ms exact-focus z0 and ~1.0-1.6s hotkey-visible z0 for Terminal→Safari.
- Interpretation: WindowServer's real user-click activation path is the fast path Safari honors; the private SLPS event-record `makeKeyWindow` is not equivalent to a global click routed by WindowServer.
- Constraint: raw titlebar clicking has serious UX risks: pointer movement, accidental clicks if geometry is stale, panel obstruction, no exposed titlebar point, click monitors treating it as user input, and possible titlebar double-click/drag side effects. Use as evidence for the desired activation mechanism, not as a default fix yet.

### 2026-05-18 — Guarded no-cursor click fallback

- Apple docs show modern `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` and `post(tap:)` route events through the WindowServer event stream, and `CGWarpMouseCursorPosition` moves the cursor without events. The modern CGEvent click path was fast but moved the cursor.
- The old `CGPostMouseEvent` symbol is marked unavailable by the macOS 26.5 SDK, but it still exists at runtime. Calling it through `dlsym` with `updateMouseCursorPosition=false` returned success, activated Safari, and preserved cursor position.
- Implemented `nativeFocusMode=noWindowsAxActivateClickFallback`:
  - standard no-windows AX activation still runs for focus semantics,
  - a 60ms background fallback checks whether the target is already z0,
  - if not z0, it posts a `CGPostMouseEvent` down/up only when the target is the top routable window at a titlebar candidate point,
  - if no exposed point exists, it falls back to the existing target-only z repair.
- Safety fix: the first direct click implementation trusted global z-list prefix and could misroute if a candidate point was actually covered. The final code requires `nativeTopRoutableWindow(at:) == targetWid` and treats AltTab/panels as blockers while ignoring non-routable Dock backing surfaces.
- Direct matrix, final CGPost fallback, six reps each:
  - Terminal→Safari z0: 181.68, 118.29, 0.05, 0.04, 0.05, 0.05ms; median 0.05ms.
  - Safari→Terminal z0: 200.04, 169.54, 0.06, 0.06, 0.05, 0.08ms; median 0.07ms.
  - Cursor stayed fixed at 640,640 during direct fallback validation.
- Hotkey probe remains confounded by launching/quitting the probe process, but it still showed all tested transitions succeeding. Short down-time reps were generally ~57-204ms z0; longer hold times include probe/panel artifacts up to ~525ms.

### 2026-05-18 — Post-profile click-after and 60ms fallback

- `sample 31325 25` during hotkey stress before the latest patch showed the main thread spending substantial sampled time in the +200ms `CLICKAFTER` diagnostic AX focused-window lookup.
- Fix: the delayed click-after probe now returns on-main if the frontmost pid still matches the clicked pid; only actual mismatches dispatch the AX focused-window lookup to `BackgroundWork.accessibilityCommandsQueue`.
- Post-fix sample `/tmp/alttab-profile/sample-hotkey-postclickafter-20260518_041022.txt` no longer showed the main thread blocked in `AXUIElementCopyAttributeValue` from that diagnostic path.
- A/B delay evidence:
  - 40ms improved some direct outliers but hotkey variance was mixed, with one ~366ms outlier.
  - 60ms had the best worst-case balance in this environment.
  - 80ms remained good but was not better than 60ms after the diagnostic fix.
- Final dev run, `nativeFocusClickFallbackDelayMs=60`:
  - direct `/tmp/alttab-profile/dynamic-focus-clickfallback80-20260518_042143.json`: Terminal→Safari median 0.06ms/worst 116.17ms; Safari→Terminal median 0.13ms/worst 196.62ms.
  - hotkey `/tmp/alttab-profile/dynamic-hotkey-clickfallback80-20260518_042354.json`: all 18 transitions succeeded; worst z0 278.48ms.

### 2026-05-18 — Exact original upstream AltTab focus body

- Added temporary `nativeFocusMode=originalAltTab` to execute the pre-local-change upstream focus body:
  - enqueue on `BackgroundWork.accessibilityCommandsQueue`,
  - `SLPS(userGenerated)`,
  - `makeKeyWindow`,
  - `AX focusWindow`,
  - `DispatchQueue.main.asyncAfter(50ms) { previewSelectedWindowIfNeeded() }`.
- Built dev dylib `fc69a1dcce4d16657ca728e19bf319b580a92e16`, launched PID `86996`, and ran exact-window buffered probes with captures/z-fixes disabled.
- `/tmp/alttab-profile/originalAltTab_exact_20260518_015746.txt`:
  - Terminal→Safari first z0: 1000.22, 750.12, 750.03, 500.08, 1250.17, 750.02ms; median 750.08ms.
  - Safari→Terminal first z0: 200.07, 300.25, 200.21, 200.08, 200.28, 200.15ms; median 200.18ms.
- App-side `AXFOCUS` logs for Safari showed the delay mostly inside Safari's AX action in many reps:
  - Safari AX phase examples: 753.9, 541.7, 583.2, 925.2, 670.7ms.
  - Terminal AX phase examples: 1.2, 38.3, 2.2, 19.3, 34.2, 38.7ms.
- Result: the original upstream focus body has now been measured. It is not faster for Terminal→Safari; the remaining fast-path gap is between private SLPS/AX focus and a real WindowServer-routed click.

### 2026-05-18 — Stuck input capture / apparent UI freeze

- User reported AltTab entered a state where clicking other apps no longer worked; they killed AltTab from another account.
- `/tmp/alttab-run.log` was incomplete because the active dev run logged to its foreground terminal. Polling the live Codex exec session recovered PID 34492 logs through the kill.
- PID 34492 was alive and processing events until `Exiting after receiving signal 15`; the tail showed continuous `REFRESH reason=window-moved-resized` lines up to 11:40:54, so this was not a crash or total main-thread deadlock.
- During the reported click-frozen period, there were no global `MOUSE` down logs. Since the global monitor only sees events that pass through AltTab's CGEvent tap, the likely failure is a stuck AltTab input-capture session swallowing mouse events before the global monitor.
- Code audit found unsafe capture behavior:
  - outside left mouse-down was swallowed and did not hide until mouse-up,
  - outside right/other mouse-down was swallowed and did not hide,
  - `hideUi()` deferred `CursorEvents.toggle(false)` to the next runloop,
  - duplicate `focusSelectedWindow` debounce returned without hiding the UI.
- Mitigation implemented:
  - `hideUi()` synchronously disables `CursorEvents` and resets trackpad capture before hiding the panel,
  - outside mouse-down now hides immediately for left/right/other buttons,
  - stale capture older than `inputCapturePassthroughMs` hides and passes the click through,
  - `inputCaptureWatchdogMs` hides any still-open capture session,
  - duplicate focus debounce hides the UI instead of leaving capture armed.
- Validation: with `inputCaptureWatchdogMs=2000`, forced `--show=0` produced `[DIAG CAPTURE] watchdog hiding stuck input capture after 2000ms`; defaults were restored to `inputCaptureWatchdogMs=15000` and `inputCapturePassthroughMs=3000`.

### 2026-05-18 — Par↔Mac flashing regression

- User reported Parallels↔Mac flashing had returned after the latest fixes.
- Recent focus logs showed Par↔Mac still used the Parallels-specific path, not the native Safari click fallback, so the click fallback was not the direct cause.
- The visible regression correlated with the curtain timing:
  - older stable behavior used a 200ms Parallels curtain,
  - commit `23542c25` made all Parallels-involved transitions default to 30ms,
  - live Par→Mac logs showed activation/focused-window notifications often hundreds of ms after the first SLPS/AX focus signal.
- First fix: make the curtain adaptive instead of globally short:
  - Mac↔Par boundary: `parCrossBoundaryHideUiDelayMs=200`,
  - Par↔Par/same-boundary: `parSameBoundaryHideUiDelayMs=30`,
  - explicit `parHideUiDelayMs` remains a manual override.
- Validation: hotkey simulation produced `parHideScheduled ... 200ms sourcePar=true targetPar=false` and `parHideScheduled ... 200ms sourcePar=false targetPar=true`.
- Follow-up evidence: user still saw flashing. External 10ms z-order sampling reproduced the problem:
  - Par→Mac sample: source Teams stayed top until ~490ms after hotkey in one run, later than the 200ms curtain.
  - Mac→Par sample: target Teams became top around ~346ms after hotkey in one run, also later than the 200ms curtain.
- Final fix: cancel delayed panel display once focus is committed, then readiness-gate Par hide:
  - `parHideScheduled` now logs `min-max` delay,
  - `parHideNow` fires only after `topVisibleAppWindowId() == targetWid` and min delay elapsed, or at `parHideMaxDelayMs`,
  - defaults: `parHideMaxDelayMs=1200`, `parHidePollIntervalMs=25`.
- Validation after final fix:
  - Six sampled Par↔Mac reps showed exactly one top-window transition, no bounce back.
  - Matching app logs showed `parHideNow ... ready=true` for all sampled reps; no `ready=false` timeout occurred.

### 2026-05-18 — Shift focus probe and safe panel evaluator

- Added `ai/post-shift-probe.swift` and wired `SHIFT_PROBE=1` into the evaluators. It posts Shift down/up only, so it validates which app receives keyboard focus without inserting text or sending Enter/Tab into Terminal.
- Real global hotkey simulation is not reliable on this machine: synthetic Command-Tab can be intercepted by macOS/app behavior instead of AltTab's Carbon hotkey path and previously routed input back into Terminal. Treat those runs as invalid unless done on an isolated desktop/window with explicit opt-in.
- Added `ai/eval-switch-transition.sh` to exercise AltTab's actual panel/session selection via `--show=0`, `--selection-state`, and `--focus-target`, avoiding global keystrokes while still testing the selection, hide, focus, z-order, and sibling-intrusion path.
- Sacrificial native app matrix with Shift probe: 18/18 panel-driven A↔B switches passed across 20/45/100ms show-to-focus delays; every run ended on the target, with no post-z0 flicker, no source reappears, and no sibling intrusions.
- Terminal↔Safari panel-driven validation with exact window IDs and Shift probe:
  - Terminal→Safari z0: 148.9, 247.0, 278.3ms.
  - Safari→Terminal z0: 539.1, 367.7, 235.2ms.
  - No post-z0 flicker, no source reappear, and no sibling intrusion in all six reps.
- Copy and recency follow-up:
  - Safari toolbar copy probe passed 3/3 (`Cmd-L`/`Cmd-C` pasteboard matched expected URL).
  - Safari→OneNote recency smoke passed 3/3: Safari remained top and OneNote was selected as the previous window, not stale Terminal/Outlook.
- Parallels→Safari after target-only Par→Mac z repair:
  - OneNote→Safari z0 remained variable around 716.8 and 870.5ms in the later reps, with no flicker or sibling intrusion.
  - Outlook→Safari z0 was 391.9, 785.3, 165.5ms, with no flicker or sibling intrusion.
  - The focus API logs still finish in tens of milliseconds; remaining lag is WindowServer/Parallels/native app surfacing after focus, so the readiness-gated hide remains the important flicker prevention.

### 2026-05-18 — Instruments attach profile

- Ran `xcrun xctrace record --template 'Time Profiler' --attach <AltTab pid>` for 16s while executing safe CLI panel switches with Shift probing.
- Trace files:
  - `/tmp/alttab-profile/alttab-timeprof-20260518_153907.trace`
  - `/tmp/alttab-profile/alttab-timeprof-20260518_153907-time-profile.xml`
- Switches during the attached trace:
  - Terminal→Safari z0: 210.1ms, no flicker/source reappear/sibling intrusion.
  - Safari→Terminal z0: 424.5ms, no flicker/source reappear/sibling intrusion.
- CPU samples showed expected work:
  - main thread: panel build/layout/rendering (`App.refreshUi`, `TilesView.updateItemsAndLayout`, title/status drawing) plus some z-enforcement samples,
  - background threads: AX brute-force window scans and z-cache `CGWindowListCopyWindowInfo` parsing,
  - CLI thread: JSON encoding for evaluator commands.
- The profile did not show focus waiting on a lock or a long synchronous main-thread focus block. This supports the earlier claim that remaining visible handoff delay is outside AltTab CPU execution.
- Tried `xctrace --all-processes` for a WindowServer/Safari view, but it ran past its 14s limit and was killed. Do not repeat all-process Instruments unattended on this machine.

## Current Implementation Direction

- Default native Mac↔Mac focus to the upstream-style `nativeFocusMode=original` path.
- Keep Terminal/iTerm on the same native path unless `nativeNoWindowsFocusEnabled=true` is explicitly set for an experiment.
- Keep `skyLightEventFocus`, `noWindowsAxActivateClickFallback`, `hidTitlebarClick`, and native no-windows focus behind explicit experimental flags, not as current defaults.
- Keep background z-order scanning/cache for MRU correctness, but do not block focus on z scans.
- Keep fast z-order monitoring enabled for Parallels-involved switches only by default; native fast monitoring is available behind `fastZOrderNativeMonitorEnabled` but was not beneficial in current tests.
- Remove native app-level frontmost recovery from the default focus path; keep app-level frontmost operations scoped to Parallels or explicit experiments.
- Keep diagnostics with ms timestamps and `AXFOCUS` phase breakdown.
- Keep input capture fail-closed:
  - `inputCaptureWatchdogMs=15000`
  - `inputCapturePassthroughMs=3000`
  - outside mouse-down hides immediately, not on mouse-up
  - event-tap disable remains synchronous in `hideUi()`
- Keep perf toggles available:
  - low-overhead timing: `diagnosticsLevel=perf`, `diagnosticsBasicPerfOnly=true`
  - disable captures: `thumbnailCaptureEnabled=false`, `focusOverlayCaptureEnabled=false`
  - disable z work: `zOrderCacheEnabled=false`, `zOrderFixesEnabled=false`
  - native focus experiments: `nativeExperimentalFocusModesEnabled=true` plus `nativeFocusMode=skyLightEventFocus|noWindowsAxActivateClickFallback|hidTitlebarClick`
  - Terminal/iTerm no-windows experiment: `nativeNoWindowsFocusEnabled=true`
  - native fast z-monitor experiment: `fastZOrderNativeMonitorEnabled=true`
  - click fallback delay: `nativeFocusClickFallbackDelayMs=60`
- For further work, prefer `ai/eval-switch-transition.sh` plus `SHIFT_PROBE=1` for live validation. Only use global-hotkey probes on isolated windows with explicit opt-in.

## Open Questions

| Question | Next Test |
|---|---|
| Does the real keyboard hotkey path differ from the safe CLI panel evaluator? | Only test on isolated sacrificial windows with explicit hotkey opt-in, buffered external z sampling, and Shift-only focus probing. |
| Is Safari's delayed z0 caused by multiple open Safari windows or a specific tab/window state? | Repeat the `TARGET_INDEX` evaluator against a fresh Safari window set and another many-window browser/app. |
| Can a per-window, non-app-level Safari-specific AppleScript window-index operation help without raising all Safari windows? | Only test as diagnostic; reject if it raises siblings or requires app-specific code. |
| Is active native `ZENFORCE` needed, rather than passive z-cache refresh? | Implement a native-only z-intent that does not set `altTabFocusTarget`, then test if repeated target-only SLPS/makeKey/AX repair reduces Terminal→Safari z0 without raising sibling Safari windows. |
| Does `CGPostMouseEvent` remain stable across macOS versions despite SDK unavailability? | Keep this path runtime-guarded and easy to disable; test on the user's current macOS and at least one older supported macOS before making it a broad default. |

### 2026-05-19 — Level pin / dense repoke experiment invalidated

- Hypothesis tested: temporarily pinning the target native window to a higher level and repeatedly re-issuing `SLPS(noWindows)+makeKey+AX focus` would prevent Safari↔Terminal bounce without bringing same-app siblings forward.
- Evidence against:
  - after dense Terminal repokes, the system reached a bad split-brain state: Safari was the Carbon/NS front process, but the visual top stack was all Terminal windows,
  - manually restoring levels and stopping AltTab did not immediately fix it; activating Safari was required to recover normal visual z-order,
  - this path directly violates the per-window invariant because it can leave all Terminal siblings visually above the true front app.
- Decision: do not use native level pinning, repeated repokes, or z0 activation clicks in the default focus path. Keep Terminal/iTerm on the last validated target-only path and use z-order observation/repair, not compositor-level pinning.

### 2026-05-19 — Tiny helper windows must not count as app z-order

- Evidence: Safari created a same-pid, layer-0 helper strip (`wid=141927`, empty title, about `1451x20`) above the selected Safari document window. The evaluator and z repair treated it as a real sibling and reported target z1 even though the visible target was correct.
- Fix: align z-order filters to require both width and height >= 40 for app-window rankings, evaluator samples, and native click routability. This keeps titlebar/tab helper strips out of target-vs-actual comparisons.
- Validation after the filter fix:
  - Terminal→Safari exact panel path: z0 at 1214.9, 817.7, 1570.0ms; no flicker, no source reappear, no sibling intrusion.
  - Safari→Terminal exact panel path: z0 at 535.5, 706.3, 646.4ms; no flicker, no source reappear, no sibling intrusion.
  - OneNote→Safari: z0 at 400.2, 1299.3, 702.8ms; no flicker/source reappear/sibling intrusion.
  - Safari→OneNote: z0 at 494.6, 473.2, 431.8ms; no flicker/source reappear/sibling intrusion.
  - Safari toolbar copy smoke passed 3/3 after focus (`match=yes`).
- Remaining fact: Terminal→Safari visual handoff is still externally slow on this desktop in some runs (>1s), but current evidence says it is not caused by AltTab CPU blocking, lock contention, or post-z0 oscillation.

### 2026-05-19 — Native slow-path cleanup and current evidence

- Re-tested Safari↔Terminal after persisted experiments had accumulated. The slow path was partly self-inflicted:
  - `nativeFocusMode=skyLightEventFocus` was persisted locally even after it stopped being the preferred default,
  - Terminal/iTerm `SLPS(noWindows)` experiments left Safari visually above Terminal until repeated recovery,
  - focus updates during an active AltTab session were rebuilding the switcher UI before hiding it.
- Fixes kept:
  - default `nativeFocusMode` is now `original`, and experimental native modes are ignored unless `nativeExperimentalFocusModesEnabled=true`,
  - Terminal/iTerm no-windows routing is opt-in with `nativeNoWindowsFocusEnabled=true`,
  - `manuallyUpdateFocusOrderForDirectFocus()` updates recency during an active AltTab session without calling `refreshOpenUiAfterExternalEvent()`, avoiding redundant panel rebuild/layout before hide,
  - native focus logs include `cgsErr`, which repeatedly showed `CGSOrderWindow(...above...)` returning `1000` on Safari/Terminal switches.
- Fixes rejected / kept off by default:
  - background native fast z-monitor did run and repaired on a serial queue, but `CGWindowListCopyWindowInfo` scans were often 25-300ms and did not materially reduce first-z0 latency; default remains `fastZOrderNativeMonitorEnabled=false`,
  - no-cursor `hidTitlebarClick` A/B caused split readiness where the visual top was Safari but Carbon/NS front stayed Terminal, so it remains experimental-only,
  - synthetic repair clicks remain off by default because prior evidence showed they did not fix z-order and can interfere with user input/copy/paste.
- Final validation with clean defaults and dev dylib cdhash `45b874e45b0c27718484b44e2c30b288dd91ade6`:
  - Safari→Terminal exact panel path passed 2/2 in final run: first z0 1315.7ms for a deep target and 444.0ms for the immediate previous target; no post-z0 flicker, source reappear, or sibling intrusion,
  - Terminal→Safari exact panel path passed 1/1 in final run: first z0 1453.6ms; no post-z0 flicker/source reappear/sibling intrusion,
  - rapid Safari→OneNote→Terminal passed: final Terminal z0, no source/first-target reappearance after z0, no flicker-after-z0 samples,
  - all bounded log scans reported zero failures.
- Interpretation: current correctness is good, but first visual z0 for Safari↔Terminal can still exceed 1s on this live desktop. Logs show AltTab focus calls complete much earlier and direct CGS raises are rejected by WindowServer (`err=1000`), so the remaining latency appears to be macOS/app/window-server handoff rather than AltTab lock contention or main-thread blocking. Do not add more aggressive native compositor interventions without new evidence.

Supersession note from later 2026-05-19 testing: this section's `nativeFocusMode=original` default was replaced after a controlled A/B. `original` still showed Terminal→Safari over one second, while `skyLightEventFocus` was consistently faster in the exact panel path and passed same-app Terminal/Safari sibling checks after native sibling AX repair was disabled.

### 2026-05-19 — SkyLight default and missing-window coverage

- Claim tested: the default native focus path can use targeted `SLEventPostToPid` without regressing selected-window semantics.
- Evidence:
  - `/tmp/alttab-ab-native-ab-native-20260519-125809` measured Terminal→Safari at `910ms`, `519ms`, `444ms` for `skyLightEventFocus` versus `1293ms`, `1277ms`, `1464ms` for `original`; `hidTitlebarClick` failed source readiness and is not safe as a default,
  - `/tmp/alttab-post-skylight-post-skylight-20260519-130227` measured Terminal→Safari `497ms`, `544ms`, `542ms`, Safari→Terminal `472ms`, `348ms`, `530ms`, and Terminal↔Parallels Desktop under `570ms`, with zero bounded log failures/warnings,
  - `/tmp/alttab-sameapp-copy-sameapp-copy-20260519-130359` measured Terminal→Terminal and Safari→Safari 3/3 with zero post-z0 same-app sibling intrusion; Safari toolbar copy passed 3/3.
- Code decision:
  - `nativeFocusMode` now defaults to `skyLightEventFocus`,
  - unsafe native modes are ignored unless `nativeExperimentalFocusModesEnabled=true`,
  - native sibling AX repair is skipped instead of raising/demoting same-app siblings.
- Test coverage decision:
  - `ai/eval-select-transition.sh` now fails when first target z0 exceeds `MAX_Z0_MS`, so slow-but-eventually-correct runs do not pass silently,
  - `ai/eval-window-coverage.sh` compares WindowServer-visible windows against AltTab `--detailed-list` and caught the class of Parallels Desktop console-window omissions; current Parallels Desktop `Windows 11` windows are present and displayable.

### 2026-05-19 — Karabiner external focus must cancel stale AltTab z-enforcement

- Claim: external keyboard-driven focus changes must be treated like user clicks for stale z-order enforcement. Otherwise AltTab can restore the old AltTab target over the app/window the user explicitly requested through Karabiner.
- Evidence:
  - corrected Karabiner target is Parallels `Outlook (classic)`, launched by `/Users/kganjam/bin/focus-parallels-outlook`; prior generic Outlook testing was the wrong surface,
  - pre-fix bounded log `external-launch-20260519-111750-75265` showed Outlook Classic became frontmost, then `FRONT_MISMATCH` restored Terminal via `SLPS(userGenerated)+AX`,
  - no-key negative control after the fix still reproduces stale restore, proving the evaluator can distinguish the bug,
  - keyed final run `/tmp/alttab-karabiner-outlook-final-20260519-113457` passed with Outlook Classic z0 at `589.836ms`, final front app `Outlook (classic)`, no flicker, no `FRONT_MISMATCH` restore, and a visible `GUARD` release log.
- Current decision: keep stale z-enforcement release on non-AltTab keyboard input and recent external activation. Keep this scoped to external input after an existing intent; do not globally disable z-enforcement, because Parallels self-activation still needs counter-raise during actual AltTab transitions.
- Regression test: run `SIMULATE_EXTERNAL_KEY=1 FAIL_KEY_EVENTS=0 SOURCE_APP=Terminal TARGET_OWNER="Outlook (classic)" LAUNCH_COMMAND="/Users/kganjam/bin/focus-parallels-outlook" bash ai/eval-external-launch-transition.sh`. The no-key control should still fail with a restore and is useful only to verify the test remains sensitive.

### 2026-05-20 — Stale focus enforcement must be short and target-scoped

- Evidence: after an AltTab focus to Teams, logs at `2026-05-20 10:21:32` showed the target visually z0 while `frontmostApplication` had changed to OneNote. The stale guard restored Teams instead of treating the later modifier activity/external launch as user intent. Separately, a temporary non-target cluster repair tried to demote unrelated app clusters such as Outlook/OBS, which made visual flashing and races worse.
- Decision: keep z repair scoped to target-app siblings only; never demote unrelated apps to "clean up" `[DIAG SAMEAPP]`. Shorten default focus enforcement/suppression windows to `2500ms` and allow delayed nonzero modifier-only events to release stale enforcement unless they are temporally adjacent to AltTab's own hotkey.
- Open validation: rerun the Karabiner Parallels Outlook/OneNote external-focus matrix and Parallels↔Mac flicker checks before considering this stable.

## 2026-05-20 — Outlook↔OneNote same-boundary flashing and slow gallery hide

- Evidence: live logs around `10:37:23-10:37:30` showed repeated Outlook↔OneNote Parallels Coherence switches. The selected target reached visual z0 and `parHideNow ... ready=true`, but `[DIAG SAMEAPP]` repeatedly reported `Outlook (classic)=7` in the top-8. One OneNote selection also issued a `PARHIDE restore attempt` even though `frontmostPid` was already OneNote's Parallels pid, extending hide to `~867ms`.
- Cause: same-boundary Par→Par handoff was still using broad/stale focus-settling assumptions: 500ms Coherence display curtain, 250ms stable hide wait, stale/cached preZ for Par target cleanup, and a PARHIDE reassert when only visual readiness lagged. Those are useful for cross-boundary Mac↔Par but make Outlook↔OneNote feel slow and add redraw/flash signals.
- Fix candidate: Parallels target focus now captures an explicit fresh pre-focus z snapshot and schedules bounded target-sibling cleanup from it. Same-boundary Par→Par display delay defaults to `100ms`, hide stable wait to `80ms`, and `PARHIDE` skips redundant reasserts when both source and target are Parallels and the target pid is already frontmost.
- Required validation: Outlook Classic→OneNote and OneNote→Outlook Classic 3x with z-sampler, bounded logs, no post-z0 source reappear, no repeated `PARHIDE restore attempt`, and perceptible hide latency under the same-boundary threshold. This is tracked as `REL-089`.

### 2026-05-20 11:01 update — no-flash behavior depends on not fighting Parallels during same-boundary handoff

- User-observed state: Outlook/OneNote/Teams switching is no longer flashing, but selecting a Parallels target from the gallery still feels slow to drop into the target.
- Recent log evidence:
  - `11:01:01.883` OneNote target focus started from an Outlook/Parallels source.
  - `11:01:01.955` initial macOS-side focus completed in `65.3ms` using `mode=userGenerated`.
  - `11:01:01.958` same-boundary hide was scheduled with `30-1200/1600ms sourcePar=true targetPar=true`.
  - `11:01:03.158` panel hid at `parHideNow +1334.6ms`, with `1197ms ready=true stable=103/80ms front=true target=#149427 top=#149427`.
  - No `PARHIDE restore attempt` occurred in this same-boundary window; no `COUNTER` or front-mismatch repair fought the target.
- Interpretation: the no-flash improvement is not because Parallels became fast. It is because AltTab stopped adding extra focus/repair signals during the same-boundary handoff and kept the gallery visible until the target was actually visual z0 and stable. The remaining delay is mostly Parallels/WindowServer visual readiness: focus calls finish in <100ms, while target visual readiness can arrive ~1.2s later.
- Preserve these invariants:
  - same-boundary Parallels→Parallels must not run delayed `PARHIDE restoreFrontmostToTarget` host focus reasserts,
  - `fastZOrderRepairFocusEnabled` should remain false by default; high-frequency z repair must not issue repeated SLPS/makeKey/AX focus calls,
  - app-level `kAXFrontmost=true` for Parallels target focus remains off by default unless a new bounded eval proves it helps without flashing,
  - `parSameBoundaryTargetUserGeneratedFocusEnabled=true` is useful for the initial guest handoff, but it is not sufficient by itself; hiding early before visual z0 reintroduces visible source exposure.
- Next latency work should target readiness prediction or a lower-risk guest-side/Parallels signal, not renewed host-side focus spam. Any proposed speedup must prove both: lower `parHideNow` elapsed and zero post-z0 source reappearance/flicker in 3x Outlook↔OneNote runs.

### 2026-05-20 11:13 update — cross-boundary Parallels reassert can also flash

- Evidence: recent logs around `11:08:56-11:08:58` showed a Mac→OneNote Parallels target finishing host focus in `60.4ms` and async make-key in `30.2ms`, then `PARHIDE restore attempt: SLPS(noWin)+makeKey(pid=96334, wid=149427) — was frontmostPid=96334` fired at `11:08:57.157`. The panel did not hide until `parHideNow ... 972ms ready=true stable=263/250ms front=true`, and a `[DIAG SAMEAPP] Outlook (classic)=6` cluster warning appeared immediately after the restore.
- Interpretation: this is the same failure class as same-boundary flashing, but on Mac→Par: frontmost process was already correct, only visual readiness lagged. Issuing another host-side SLPS/makeKey during that lag can redraw or reshuffle Coherence windows and does not reliably shorten readiness.
- Decision: delayed `PARHIDE` reassert is now allowed only when the frontmost process is actually wrong. If the target process is frontmost but the selected window is not yet visual z0, keep the gallery up and wait for the readiness/stability gate instead of fighting Parallels.

### 2026-05-20 11:45 update — pre-focus guest z-order before host switch

- Claim: Parallels flashing is mostly guest/host z-order skew. The macOS front process can be correct while the Windows guest has not yet made the selected HWND foreground, so the menu bar stays stable but Coherence windows visibly shuffle.
- Change: Parallels target focus now queues a measured Winside `SetForegroundWindow` before the host `_SLPSSetFrontProcessWithOptions`/`makeKeyWindow` sequence, then waits a small configurable `parGuestPrefocusHostDelayMs` window before host focus. This lets the guest start moving the exact HWND first without adding more host-side reasserts.
- Startup fix: Winside helper startup probing no longer monopolizes the same serial queue used by focus commands. Startup runs on a separate queue and only briefly uses the command queue for readiness checks after a status file appears.
- Evidence to collect: each Parallels target switch should now log `guestPrefocusQueued` and `guestPrefocusDone` with `ok`, `hwnd`, `list`, `set`, and `total` timings. Compare those timestamps against `AXFOCUS`, `parHideScheduled`, and `parHideNow`. A successful speedup should reduce target visual-z0 latency without `PARHIDE restore attempt` or post-z0 source reappearance.

### 2026-05-20 12:10 update — failed guest pre-focus and stack-settle curtain

- Evidence: live Outlook↔OneNote switches around `12:04:22-12:04:44` still visibly flashed. Logs showed host focus completing quickly (`AXFOCUS` mostly `10-50ms`) and target z0 eventually true, but `[DIAG SAMEAPP] top8 has Outlook (classic)=5` persisted while the gallery hid. The Winside pre-focus queue was not helping: `guestPrefocusDone` arrived `~5.0s` later with `stale-after-list`, `stale-before-list`, or `no-hwnd cache=1`.
- Cause: the persistent Winside multiline `LIST` path was stalling for its timeout and backlogging stale pre-focus requests. A one-shot `nc` `LIST` against the same helper returned in `~20ms`, so the helper was reachable; the persistent multiline reader is the unsafe piece.
- Decision: disable `parGuestPrefocusEnabled` by default and in live defaults until the Winside path proves fresh and bounded. `LIST` now uses the one-shot path first if the feature is re-enabled later.
- New hypothesis: the flicker is mostly the top Coherence stack still reordering behind the selected window. The previous hide gate only required the target to be z0 and stable; it could reveal while Outlook/OneNote sibling/source clusters were still changing. Same-boundary Par→Par now also requires the top stack signature to stay unchanged (`parSameBoundaryStackStableWindowCount=8`, `parSameBoundaryStackStableMs=250`) before hiding.
- Validation signal: after restart, recent logs should contain no `guestPrefocusQueued` while disabled. Same-boundary `parHideNow` lines should include `stack=.../250ms`; if flicker persists with target and stack both stable, the next suspect is Parallels repainting unchanged windows rather than AltTab exposing an unstable z stack.

### 2026-05-20 12:20 update — avoid Coherence capture churn during the switcher

- Evidence: after the stack-settle gate, visual flicker improved but did not disappear. Logs still showed panel-open thumbnail capture immediately after `showPanel` (`visible thumbnail refresh reason=show count=44-48`) while Parallels had `~23` Coherence windows in the model. Those captures use `CGSHWCaptureWindowList` for Coherence windows, which hits the WindowServer/Parallels compositor path that has already been identified as flicker-prone.
- Decision: skip Parallels Coherence thumbnail captures while the AltTab panel is open (`skipCoherenceThumbnailsDuringPanel=true`). This preserves cached thumbnails but avoids asking Parallels to repaint many guest windows during the exact focus/gallery handoff where flicker is visible.
- Evidence after restart: the panel-open capture count dropped from `48` to `18` in the Terminal gallery path, confirming Coherence windows were excluded. Need a 3x Outlook/OneNote/Par↔Mac validation to confirm flicker reduction in the actual Coherence path.
- Additional focus decision: default `parallelsTargetUserGeneratedFocusEnabled=true`. A prior Mac→Outlook sample with `mode=noWindows` hit hard max with `ready=false`, `front=true`, and Safari still visual z0; `userGenerated` is the safer target-window activation mode for Parallels targets.
- Latency decision: cross-boundary Coherence panel display delay is live-set and defaulted to `300ms` instead of `500ms`; this affects how quickly the gallery appears on a held shortcut, not the post-selection target readiness gate.

### 2026-05-20 13:15 update — OneNote target z0 with unrelated clusters still underneath

- Evidence: last live OneNote/Outlook/Terminal switches around `12:35-12:39` showed the selected OneNote or Outlook window reaching macOS visual z0 and the target Parallels proxy pid becoming frontmost, but `[DIAG SAMEAPP]` still reported `Outlook (classic)=2` and `Terminal=4` in top-8. A manual Winside read showed the Windows guest top stack had Outlook above OneNote while `FG` sometimes returned the blank `prl_cc` helper HWND; the guest foreground signal can therefore diverge from the visible Coherence stack.
- Interpretation: this is not the old “target app siblings all raised” regression. It is a cross-app cluster/skew problem: unrelated app/window clusters can remain directly under the target. Broadly demoting unrelated clusters is still unsafe and previously made flashing/races worse.
- Change: diagnostics now log the concrete top-8 stack in every `[DIAG SAMEAPP]`, emit `[DIAG ZPROMOTE]` when post-focus windows are materially promoted relative to the pre-focus snapshot, and emit `[DIAG WINSIDEFG]` at perf level for Parallels hide scheduling/hide time.
- Event-storm fix: Coherence startup/display changes can emit hundreds of `window-moved-resized` AX events in under a second; each one previously requested a z-order review and cache generation. Those reviews are now coalesced into one delayed `window-moved-resized-batch`, reducing drag jitter and stale-cache churn.
- Guest pre-focus safety: Winside pre-focus is re-enabled by default only with a hard freshness guard (`parGuestPrefocusMaxAgeMs=350`). If the command queue is blocked, the SET is skipped before it can fire late; stale guest SETs must never occur seconds after the user has moved on.
- Validation required: after a user-observed OneNote/Outlook flash, inspect `SAMEAPP top=[...]`, `ZPROMOTE`, `WINSIDEFG`, `parHideNow`, and any `window-moved-resized-batch` lines in the bounded window. Do not “fix” unrelated clusters by broad CGS demotion unless a specific, reproducible promotion delta proves AltTab caused it and the repair is scoped.

### 2026-05-20 14:30 update — clicking broke because guest foreground diverged from macOS foreground

- Evidence: live Outlook/Terminal logs around `14:20:32-14:20:33` showed the selected Outlook Calendar Coherence proxy became macOS visual z0 and `frontPid==targetPid`, yet `[DIAG WINSIDEFG]` still reported the Windows guest foreground HWND as `Microsoft Visual Basic for Applications`, the previous Outlook window. The same pattern occurred when selecting other Outlook windows: macOS focus/z-order looked correct while Windows-side keyboard/click routing was still attached to the old HWND.
- Why tests missed it: the current readiness checks asserted macOS visual z0, front process, and AX focus, but did not fail when guest `GetForegroundWindow()` disagreed with the selected Coherence target. That allows a switch to pass while the first click or Karabiner hotkey still routes to the previous guest window until the user manually clicks inside the target.
- Fix direction: restore bounded guest pre-focus, but do not use the old host-side `LIST` cache path on the focus critical path. The helper now supports `SETTITLE64 <base64 title>` so title matching and `SetForegroundWindow` happen inside Windows in one TCP round-trip. Host fallback to `LIST` remains only for older helpers.
- Safety constraints:
  - `parGuestPrefocusEnabled` must be true only with `parGuestPrefocusMaxAgeMs` guarding stale commands; a queued guest `SET` must skip rather than fire seconds after the user moved on.
  - Winside startup/focus logs must be visible at perf level; hiding startup failures at verbose level caused us to miss that the helper was not available.
  - Validation for Parallels Coherence must include guest foreground agreement: after `parHideNow`, `WINSIDEFG` should match the target window title/HWND or the run is not ready even if macOS z0/frontPid are correct.

### 2026-05-20 15:20 update — Mac/Windows logs need comparable clocks and external-front validation

- Evidence: after the bounded `SETTITLE64` path, an Outlook title beginning with emoji still failed guest pre-focus because macOS logged `⭐️ [May 7th]...` while Windows returned replacement characters like `?? [May 7th]...`. The failed `SETTITLE64` let OneNote remain the Windows foreground during an Outlook target switch, which produced source reappearance after target z0.
- Fix: the Winside helper now normalizes title keys and supports a conservative fuzzy-prefix match after exact/prefix/contains matching. The focus path uses the focus queue and `SETTITLE64` only; it no longer waits behind unrelated persistent-socket `LIST` calls, and stale queued requests skip instead of firing late.
- Timing rule: every Mac diagnostic line now includes `utcMs=<epoch-ms>`, and Winside `PING`, `FG`, `SET`, `SETTITLE64`, and error responses include `winMs=<epoch-ms>`. A fresh `PING`/`FG` check after dev restart showed Mac and Windows epoch-ms aligned within a few milliseconds, so bounded log regions can be correlated directly without relying on relative `t+...` clocks.
- Frontmost-cache finding: z-sampler can report `final_ns_front_pid` as the previous Parallels app even when AltTab's process-local `NSWorkspace.frontmostApplication`, visual z0, and AX focus all report the target. Because Karabiner and other external observers may see the same stale frontmost cache, this is a release failure, not a harmless sampler discrepancy.
- Fix direction: delayed `FRONTMOSTSET` no-window `_SLPSSetFrontProcessWithOptions` repokes must not skip just because AltTab already sees the target as frontmost. They are now generation-checked and target-z0-checked, then sent to refresh external frontmost observers.
- Same-boundary stability: `250ms` stack/target stability was too short for Parallels Outlook↔OneNote; source windows could bounce after the first target z0. Defaults now use `700ms` for same-boundary hide/stack stability. This intentionally trades some gallery-hide latency for less flashing.

### 2026-05-20 15:35 update — z-sampler front signals must be interpreted separately

- Evidence: a bounded OneNote→Outlook run showed visual z0, AX focused window, AX focused app pid, guest `WINSIDEFG`, and Carbon front process all aligned with the Outlook target, while the sampler process's `NSWorkspace.shared.frontmostApplication` still reported the old OneNote pid. The sampler is a command-line process without an AppKit runloop, so this field can be a stale cached observer, not ground truth.
- Decision: `ai/z-order-sampler.swift` now emits `utc_ms`, `ax_front_pid`, `carbon_front_pid`, and `ns_front_pid` separately. `front_pid` remains the best active/focused pid, preferring AX then Carbon. Mechanical pass/fail should use visual z0 plus AX/Carbon/AX-focused-window; stale `ns_front_pid` is a warning unless corroborated by AX/Carbon/System Events.
- Keep the `FRONTMOSTSET` repokes for Parallels targets anyway: they are cheap and may help real external observers, but do not keep adding focus hacks solely to make sampler `NSWorkspace` change.

### 2026-05-20 15:45 update — post-build logs need explicit anomaly semantics

- Evidence: the current PID slice had many bad-looking runtime signals but almost none were machine-actionable: `SAMEAPP` was logged 42 times, `FRONTMOSTSET skipped` 31 times, stale-generation skips 16 times, and zero explicit warning/anomaly lines. Several delayed `post-manualUpdate` probes fired after newer AltTab targets or user clicks, so they were stale noise rather than current-state failures.
- Fix: add `[DIAG ANOMALY]` for current focus invariant failures after the panel is gone: target missing/not z0, top pid mismatch, AX focused app mismatch, or AX focused window mismatch. Add `[DIAG MONITOR]` for OK/skipped/pending checks. Delayed `post-manualUpdate` probes are now generation-gated before logging `SAMEAPP`, and every dev/install build runs a bounded `ai/monitor-runtime-anomalies.py` pass after launch.
- Rule: `SAMEAPP` alone is no longer a release signal; it is broad and noisy on high-window-count desktops. The release signal is `[DIAG ANOMALY]` or eval/sampler evidence that the selected target state does not match current z0/AX/guest state.

### 2026-05-20 16:00 update — anomaly detection must trigger bounded repair

- Evidence: at `15:39:33.738`, AltTab selected Outlook target `#149448`. It reached z0 and hid the panel at `15:39:35.097`, but by `15:39:36.325` an untracked same-pid Outlook window `#154541` was visual z0 while AX still reported the selected target `#149448` as focused. `[DIAG ANOMALY] targetNotZ0` correctly detected the mismatch, but it only logged; no repair was attached to the invariant failure.
- Cause: existing z-enforcement default lifetime is `2500ms`; the same-app Outlook raise happened just after that window, and the old `enforceZOrder()` branch explicitly skipped late same-app blockers after the target had once reached z0, assuming they were legitimate dialogs. That assumption is wrong when AX focus remains on the selected target.
- Fix: `[DIAG ANOMALY]` now calls a bounded current-target repair. The repair runs only if the AltTab target is still current and not invalidated by user focus, skips if AX focus moved to a real same-pid dialog/sibling, and otherwise pairwise raises the selected target plus Parallels AX recovery. The old same-app-dialog skip now only applies when AX focus actually moved away from the target.
- False-positive fix: `CLICKMISROUTE` now requires the click point to fall inside the recent target window bounds. A user intentionally clicking Terminal elsewhere within five seconds of an AltTab focus should not be reported as a misroute.
