# AltTab Focus / Z-Order Hypotheses

Living decision log for the current AltTab performance/correctness work. Keep this updated whenever a hypothesis is tested, disproven, or promoted into a design constraint.

## Current Claims

| Claim | Status | Evidence | Decision |
|---|---|---|---|
| UI/focus measurements need at least 3 clean repetitions. | Standing rule | User activity can overlap unattended runs, and real clicks/typing/display changes can look like focus/z-order regressions in samplers and logs. Single samples already produced contaminated observations during this work. | Run each validation at least 3 times when feasible; mark runs with user activity or external app/display events as contaminated and rerun before drawing conclusions. |
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
| Targeted `SLEventPostToPid` is the best current non-Terminal native focus path. | Supported | 2026-05-18 matrix: `originalAltTab` Safari focus was ~530-1100ms and one Safari copy probe failed at 0.8s because Safari was not yet the real front/key app. `skyLightEventFocus` Safari reps were ~61-89ms, copy passed 3/3, and deeper Safari-window probes showed no post-z0 sibling intrusion. | Default non-Terminal native focus to `skyLightEventFocus`; keep Terminal/iTerm routed through target-only no-windows focus before checking the mode. |
| Terminal/iTerm must not use the SkyLight click path by default. | Supported | User observed Terminal focus bringing all Terminal windows forward. The target-only no-windows path puts the selected Terminal window z0 while preserving Safari/source windows above unrelated Terminal siblings. After moving the Terminal guard before `nativeFocusMode`, a `skyLightEventFocus` Terminal probe logged the `nativeMultiWindow` target-only path. | Always route Terminal/iTerm through `focusNativeMultiWindowNoWindows` before experimental native modes. |
| Safari startup/restart is not what raises Safari windows. | Supported | `ai/eval-restart-zorder.sh Safari` before/after restart showed identical top order and no top changes; watched Safari stayed z1 with the same Safari count in top16. | Treat apparent restart clustering as existing z-order/focus-mode pollution, not launch-time activation. |
| Copy/paste regression is catchable with a focused keyboard smoke test. | Supported | `ai/eval-copy-after-focus.sh Safari` focuses the target, posts exact `Cmd-L`/`Cmd-C` via CGEvent, and asserts pasteboard equals Safari's current URL. It reproduced a failure when `originalAltTab` had not made Safari key by 0.8s. | Run this probe after focus-path changes; release known synthetic modifiers before/after key tests. |
| Synthetic focus clicks must not look like user clicks to AltTab. | Supported | After enabling native z enforcement, `SLEventPostToPid` focus clicks were observed by AltTab's global mouse monitor at the stationary cursor position, resolving to Terminal and canceling the z-order intent. This produced a false Terminal-over-Safari flicker and copy failure. | Mark synthetic focus clicks and ignore matching short-window global mouse events before updating `lastMouseClickTime` or releasing z enforcement. |
| Native focus needs short-lived z enforcement even without input-capture guard. | Supported | The evaluator caught late Safari sibling overtakes (~+1.17s) and Terminal sibling overtakes (~+0.31s). Adding native z-intents with pre-focus z snapshots fixed final two-cycle validation: Safari first z0 ~80-129ms, copy passed, Terminal first z0 ~159-188ms, no post-z0 flicker or sibling intrusion. | Use `armNativeFocusZOrderIntent` for SkyLight native focus and Terminal/iTerm target-only focus; do not set `altTabFocusTarget` for this path. |
| `CGPostMouseEvent(... updateMouseCursorPosition=false ...)` gives the fast click path without moving the cursor. | Supported | Runtime dlsym of the SDK-unavailable symbol succeeded. Probe from cursor 640,640 clicked Safari titlebar at 178,57, returned success, left cursor at 640,640, and made Safari z0. Integrated guarded fallback with exposed-point validation; final Terminal↔Safari matrices with a 60ms fallback had no misses and worst direct z0 ~197ms / hotkey z0 ~278ms, versus prior 750-1600ms outliers. | Keep as guarded rollback/diagnostic mode. Current default uses targeted `SLEventPostToPid`, which avoids global cursor routing and was faster in the latest Safari copy/z-order matrix. |
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

- Default native Mac↔Mac focus to `nativeFocusMode=skyLightEventFocus` for non-Terminal windows.
- Route Terminal/iTerm through target-only `SLPS(noWindows) + makeKeyWindow + AX focus` before considering native focus mode.
- Keep `originalAltTab`, `noWindowsAxActivateClickFallback`, and `hidTitlebarClick` available as experiment/rollback modes, not as current defaults.
- Keep background z-order scanning/cache for MRU correctness, but do not block focus on z scans.
- Remove native app-level frontmost recovery; keep any app-level frontmost operation Parallels-specific only.
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
  - native focus experiments: `nativeFocusMode=userGeneratedFocus|noWindowsFocus|noWindowsRaise|userGeneratedRaise|originalAltTab|skyLightEventFocus|noWindowsAxActivateClickFallback|hidTitlebarClick`
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
