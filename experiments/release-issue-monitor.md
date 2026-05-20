# AltTab Release Issue Monitor

This is the release-gate reference for the AltTab focus/z-order work. Before shipping a new build, every issue class below must be checked against the exact candidate build, with artifacts saved and logs reviewed. A build is not releasable if any item is `FAIL`, `PARTIAL` without a written risk acceptance, or `UNCHECKED`.

## Non-Negotiable Release Rules

- Run every applicable check at least three times. A single clean run is not evidence.
- Treat real user activity during an eval as contamination. Rerun instead of explaining it away.
- UI-driving experiments must snapshot the starting top-level app/window and restore AltTab/the desktop to that state before exiting. If the user changes the top-level window during the run, do not restore over the user; mark the run contaminated and preserve the user's state.
- Every run must have bounded log markers and an end marker.
- Always inspect `/tmp/alttab-run.log` for anomalies, not just script exit codes.
- Always inspect `*.zscan.txt`, `*.logscan.txt`, and the raw JSONL samples.
- Run `bash ai/eval-popup-storm-guard.sh <context>` before and between UI evals; exit `86` means stop immediately and do not trust the run.
- Generate and review an LLM prompt with `ai/eval-prompt-review.sh` for focus/z-order changes.
- Review `experiments/release-risk-code-review.md` and update it for any new risky code hotspot or changed mitigation.
- Do not run destructive keyboard probes against the user's live Terminal. Use Shift-only probes for focus delivery.
- Do not ship with TCC prompts, stuck permission-popup flushing, or repeated permission dialogs.
- Do not ship a build that only works after restarting AltTab unless restart behavior itself was explicitly tested.
- Do not release from a dirty working tree unless every dirty file is accounted for in the release notes.

## Current Build Audit

Date: 2026-05-19.

Candidate checked:

- Process: `/Applications/AltTab.app/Contents/MacOS/AltTab`, PID `11575`, PPID `1`.
- Dev dylib: `dev/AltTabCore.dylib`, cdhash `e9773c026c081dc687d5dd5b3ea1c56a6c0f6c34`.
- Runtime defaults: `diagnosticsLevel=perf`, `diagnosticsEnabled=1`, `zOrderFixesEnabled=1`, `zOrderCacheEnabled=1`, `thumbnailCaptureEnabled=1`, `focusOverlayCaptureEnabled=1`, `nativeFocusMode=skyLightEventFocus` default after deleting the user override.
- `bash ai/build.sh compile`: passed after the latest code edits.
- Current result: `NOT RELEASABLE`.
  - Latest broad suite `/tmp/alttab-focus-suite-release-risk-20260519-141048` exposed repeated `UserNotificationCenter` frontmost storms, stale frontmost restores, external Outlook failures, and contaminated copy/focus results.
  - Added `ai/eval-popup-storm-guard.sh` and log-scanner checks so future evals abort immediately instead of continuing through this contamination.
  - Previous targeted passing artifacts remain useful history only; they are not a release pass for the current dirty tree.

## Issue Classes

| ID | Issue | Failure Signal | Required Checks | Current Coverage |
| --- | --- | --- | --- | --- |
| REL-001 | Selected-window focus regresses to app-wide activation | All Terminal/Safari/Safari-profile/Parallels siblings come forward, or `[DIAG SAMEAPP]` after focus | Same-app multi-window z-sampler, top-8 sibling intrusion checks, manual visual check; native cross-app switch eval must fail if `same_app_top8_after_z0_max > 1` or `same_app_above_after_z0_max > 0` unless the sibling was already immediately above target before focus | Partial: sampler exists; current build still needs full rerun |
| REL-002 | Visual z-order differs from AltTab list order | Visually top window is not first/expected in AltTab list | Compare `CGWindowListCopyWindowInfo` z0 with `--selection-state` and `--detailed-list` | Partial |
| REL-003 | Target app activates but target window does not foreground | Menu bar changes to Safari but Safari window stays behind; traffic-light buttons inactive | Front process + AX focused window + visual z0 must all match target | Partial; current logs show split/focus latency failures |
| REL-004 | `focusSelectedWindow` has no selected target | Log line `focusSelectedWindow ... wid=nil` | `ai/eval-log-anomalies.py` must fail `nil-focus-target` | Covered; latest targeted logs passed after nil-target guard |
| REL-005 | Slow native Safari ↔ Terminal switching | Any native focus target exceeds threshold or visible z0 > expected | 3x Terminal→Safari and 3x Safari→Terminal with z-sampler, Shift probe, log scan | Covered for latest targeted run: 3x each under `1000ms` |
| REL-006 | Deep z target switching is slower or wrong | Target several windows down never reaches z0 or oscillates | Run target indexes `0`, `1`, middle, and deep with `SOURCE_INDEX`/`TARGET_INDEX` | Gap |
| REL-007 | Variable Alt-Tab timing breaks selection/focus | Different key hold durations, repeated tabs, or release timing select wrong window | Run show/select/focus with variable `SHOW_TO_SELECT_MS`, `SELECT_TO_FOCUS_MS`, and tab counts | Partial |
| REL-008 | Rapid overlapping Alt-Tab corrupts recency | Safari stays between Terminal windows; stale first target wins | `ai/eval-rapid-overlap-transition.sh` 3x plus stale-event scan | Partial |
| REL-009 | Recency/order moves a recently used app down | Outlook/Safari/Terminal drops below older windows | Focus A→B→C and verify list order against actual focus history | Gap/partial |
| REL-010 | AltTab restart corrupts z-order/list order | After restart, all Safari windows come forward or list first item wrong | `ai/eval-restart-zorder.sh` plus same-app z scan | Partial |
| REL-011 | Mac → Parallels Coherence flicker | Old Mac window flashes after target Parallels window reaches z0 | z-sampler post-z0 flicker/source-reappear count must be zero | Partial |
| REL-012 | Parallels → Mac flicker | Parallels window reappears after Mac target z0 | z-sampler post-z0 flicker/source-reappear count must be zero | Partial |
| REL-013 | Parallels app handoff exceeds readiness gate | `parHideNow ready=false`, wrong `top`, wrong `front`, or elapsed too high | `ai/eval-log-anomalies.py` par-hide checks | Covered mechanically |
| REL-014 | Parallels Coherence apps unresponsive during display transition | OneNote/Outlook slow to recover, span monitors, fail resize | Manual display topology matrix and z/focus snapshots before/after | Gap |
| REL-015 | Display topology breaks system UI | Menu bar/dock disappear; laptop display black; mirroring required | External-only, dual, laptop-only, mirroring transitions; verify menu bar/dock/laptop panel | Gap/manual |
| REL-016 | Parallels Coherence windows span both monitors | Outlook/OneNote frame not constrained after display switch | AX frame check and screenshot/visual check after topology changes | Gap |
| REL-017 | Window drag jitter | Teams/Parallels drag stutters due `window-moved-resized` storms | Drag a Coherence window and verify no repeated full z review while mouse is down; bounded logs should show coalesced `window-moved-resized-batch`, not hundreds of `window-moved-resized` reviews | Partial; current patch coalesces reviews, needs manual/eval proof |
| REL-018 | Mouse click fights focus guard | Clicked app does not receive input; `CLICKAFTER` says input would route to different app | Click target and verify front process + AX focused window at +200ms/+500ms | Partial |
| REL-019 | Thumbnail click path wrong | Clicking AltTab thumbnail focuses wrong app/window or brings all windows forward | Simulate thumbnail clicks across native/native, Mac/Par, Par/Mac | Gap |
| REL-020 | Thumbnails stale/not updating | AltTab preview shows old content | Thumbnail refresh eval with changed window content and capture age checks | Gap |
| REL-021 | Thumbnail capture causes flicker | Coherence app flashes or cursor flickers during background/panel/focus-settle capture | Run with thumbnails on/off and compare z/flicker samples; bounded logs must show `thumbnail gate begin` before Parallels focus, no `visible thumbnail refresh`/screenshot worker touching WindowServer during the gate except blocked logs, and `thumbnail gate end` only after `parHideNow`/panel hide | Partial; current candidate adds a lock-backed capture gate and worker-side rechecks |
| REL-022 | Copy/paste breaks after focus | Copy from Safari toolbar fails or pastes old data | `DELAY=1.2 bash ai/eval-copy-after-focus.sh Safari` 3x | Covered mechanically |
| REL-023 | Keyboard sniffer consumes/reroutes keys | Terminal receives Enter/Tab during tests, or normal shortcuts fail | Safe Shift-only focus probes; no synthetic Enter in live sessions | Partial |
| REL-024 | Input capture never releases | User cannot click other apps; watchdog fires | No `[DIAG CAPTURE] watchdog hiding stuck input capture` in bounded logs | Covered for latest targeted logs; full release matrix still required |
| REL-025 | AltTab prevents clicking other apps | UI effectively frozen until AltTab is killed | Input-capture watchdog check plus manual click-away check | Partial |
| REL-026 | Permission dialog spam | TCC/permission prompts repeat | `ai/tcc.sh` inspect, no prompt logs, no stuck-popup flush, no repeated Screen Recording timeout loop | Partial; Screen Recording prompt-capable probe now preflights and backs off |
| REL-027 | Stuck permission-popup flusher kills system services | UserNotificationCenter/usernotificationsd kill loop | `flushStuckAuthPopupsThreshold=0`, no `stuck-popup detection` logs | Covered mechanically |
| REL-028 | Dev/install breaks TCC | Accessibility/Screen Recording re-prompt after dev loop | Use `bash ai/build.sh dev`, not `install`, and inspect TCC only if needed | Covered in process |
| REL-029 | Dev launch exits after build | AltTab starts then disappears after `ai/build.sh dev` | PID must survive after build with PPID `1` | Covered; current build alive |
| REL-030 | Build script or signing changes invalidate bundle seal | TCC grants drop or app prompts | Use install only for shim/Pods/entitlements; verify code signing bottom-up | Partial |
| REL-031 | Karabiner `fn+o` → Parallels Outlook Classic fails | Outlook Classic never fronts or stale Terminal restored | `SIMULATE_EXTERNAL_KEY=1 FAIL_KEY_EVENTS=0 SOURCE_APP=Terminal TARGET_OWNER="Outlook (classic)" LAUNCH_COMMAND=/Users/kganjam/bin/focus-parallels-outlook bash ai/eval-external-launch-transition.sh` 3x | Partial; must rerun on candidate |
| REL-032 | Karabiner/external focus mistaken for AltTab stale restore | `FRONT_MISMATCH ... restoring` after external hotkey | External eval must use `--fail-front-restore` | Covered mechanically |
| REL-033 | Normal AltTab mistaken for external keyboard input | `released stale z-order enforcement by external keyboard` during regular AltTab | Log scan after manual and eval AltTab; reject adjacent hotkey releases | Partial |
| REL-034 | Hammerspoon interference | External focus/hotkeys fight AltTab | Verify Hammerspoon not running and not startup-enabled | Gap/manual |
| REL-035 | Spaces/desktops break z-order | Changing Space makes list order/focus stale | Multi-Space switch matrix with z-sampler and list order check | Gap |
| REL-036 | Window open/close events break ordering | New/closed windows produce stale list or wrong first item | Create only test windows, close only test windows, verify lifecycle z refresh | Partial |
| REL-037 | Minimize/deminiaturize changes break ordering | Minimized/restored windows appear wrong | Lifecycle eval with minimize/deminimize and list/z-order check | Gap |
| REL-038 | Display wake/mirroring side effects | Internal display does not wake; system UI hidden | Manual system checklist; do not automate without user approval | Gap/manual |
| REL-039 | Heavy logging affects latency | Logging overhead contributes to slow switching | `LOGCOST` must stay low; compare diagnostics off/perf/trace | Partial |
| REL-040 | Debug/thumbnails/z-fixes flags mask behavior | A fix only works with debug or thumbnails off | Run core checks with normal flags, thumbnails off, z fixes off, and basic perf logs | Gap/partial |
| REL-041 | Background z-order cache blocks main thread | Main-thread lock contention or CGWindow scan delay | Instruments/Time Profiler plus log timings for z-cache requests | Partial |
| REL-042 | Unsafe native focus experiments reappear | Native level pin, repoke timers, z0 activation click, broad app activation | Log scanner fails unsafe paths; code review `Window.focus()` | Covered mechanically |
| REL-043 | CGS ordering assumptions are wrong | `CGSOrderWindow err=1000` or repair no-op | Treat `err=1000` as warning; don't rely on CGS as sole repair path | Covered as warning |
| REL-044 | App launch/quit events reorder active windows | `app-launched`, `app-quit`, `created-window` moves wrong item first | Lifecycle eval and bounded log scan | Partial |
| REL-045 | Permission/check dialogs become AltTab candidates | UserNotificationCenter or tiny helper windows pollute z order | z-sampler filters and list-order check exclude system/tiny windows | Partial |
| REL-046 | System menu bar/dock not visible after AltTab overlay | Overlay/window level or Space state hides system UI | Manual check after AltTab show/hide and display transitions | Gap/manual |
| REL-047 | Test harness leaves side effects | OBS/Hammerspoon/eval helper/running samplers affect desktop, or an eval leaves the front app/window different from the pre-test state | Preflight `pgrep` for eval tools and known side-effect apps; snapshot starting top-level app/window; restore it on clean exit; skip restore and mark contaminated if the user changes the top-level window during the run | Gap/manual |
| REL-048 | Unified exec process leaks hide reality | Too many open exec sessions, old evals still running | Preflight process audit; no long-lived shell sessions except intentional app process | Partial |
| REL-049 | Ambiguous app names test the wrong app | Mac Outlook opens instead of Parallels Outlook Classic | Tests must use exact owner/bundle/launch command | Covered by doc, must enforce |
| REL-050 | Eval false passes due missing markers/restarts/user activity | Script reports success with zero lines, wrong process, or real user clicks/keys contaminating the run | `eval-log-anomalies.py` must fail missing/empty marker and restart-after-marker; UI-driving evals must preflight `ai/eval-user-idle-guard.sh` and stop when the user is active | Covered mechanically |
| REL-051 | Manual “feels wrong” not captured mechanically | Oscillation, flashing, or delayed foregrounding not represented in pass/fail | Required prompt review plus manual notes after each candidate | Partial |
| REL-052 | Recovery logic raises target-app siblings | Any AX/CGS recovery raises a non-target same-pid window while repairing target | Code review all repair paths; log scan for `native expected sibling repair`, `native sibling AX demote`, full-stack AX fallback; z-sampler same-app checks | Partial/pass for latest same-app targeted runs; code now skips native sibling AX repair |
| REL-053 | Visible special windows missing from AltTab | Active Parallels Desktop VM window, Teams meeting, Google Meet browser window, or OBS-recorded meeting window is visible and displayable by AltTab policy but absent or not displayable in AltTab | `ai/eval-window-coverage.sh` for Parallels Desktop `Windows 11`; cross-check `--detailed-list` against CGWindow/AX windows for Teams, Safari/Chrome/Meet, and OBS before release; inspect `displayHideReasons` for false hidden causes like `notInVisibleSpace`; raw WindowServer-only windows can be off-Space proxies and should not fail unless AltTab says they should display | Partial/pass for current Parallels Desktop console; Teams/Meet/OBS still situational |
| REL-054 | Multiple AltTab instances or wrong bundle path | More than one AltTab process, process runs from DerivedData/Trash/backup path, or current PID ignores the candidate dylib | `pgrep -afil 'AltTab\\.app/Contents/MacOS/AltTab'`; verify one PID, `/Applications` path, PPID `1`, expected `$ALTTAB_DYLIB_OVERRIDE`, and candidate cdhash | Partial/process check exists, now explicit |
| REL-055 | Restart loop or PermissionsWindow cascade | `restart()` repeatedly spawns new instances, many permission windows appear, or `/tmp/alttab-restart.lock` suppresses loops | Bounded log scan for `restart()`, `restart() suppressed`, permission-denied restart, and process-count growth during dev/install | Partial/gap |
| REL-056 | Stale experimental defaults change release behavior | Old defaults leave `nativeFocusMode`, z-cache, z-fixes, overlay, capture, or permission flushing in a non-release mode | Snapshot `defaults read com.lwouis.alt-tab-macos`; compare against release baseline; reset or explicitly document every non-default before testing | Partial |
| REL-057 | Modal/dialog/popup windows get buried or hidden | Save/open dialogs, auth prompts, Parallels dialogs, or app popups appear then target z-enforcement pushes them behind parent | Create native and Parallels modal dialogs; verify untracked new popup windows remain top/selectable and are not z-restored behind parents | Gap |
| REL-058 | Hidden/bugged app windows pollute list/order | Hidden, zero-alpha, offscreen, tiny, or bugged AX windows appear in AltTab or push real windows down | Compare `--detailed-list` displayability against CGWindow alpha/layer/bounds/onscreen state; include apps with known hidden-window behavior | Gap/partial |
| REL-059 | Sleep/wake or lock/unlock breaks event taps | AltTab hotkey, mouse monitor, or trackpad/scroll event tap stops after wake; app restarts or prompts | Manual sleep/wake and lock/unlock matrix; verify event tap health, AltTab hotkey, click-away, and no restart/permission loop | Gap/manual |
| REL-060 | Search/filter changes selection or panel geometry incorrectly | Search recenters panel, preserves stale selected window, or focuses wrong filtered item | Show panel, type search, cycle results, clear search; verify selection-state, geometry, target focus, and no nil-target release | Gap |
| REL-061 | Windowless/app-only mode violates standard-window invariants | `activateAllWindows` leaks into standard window mode, or app-only/windowless mode stops working | Test `Preferences.onlyShowApplications` on/off and a windowless app; code review `activateAllWindows` remains limited to app-only/windowless branches | Partial |
| REL-062 | Modifier/key state remains stuck after switching/evals | Option/Cmd/Shift stays logically down; copy/paste or shortcuts fail after AltTab or probes | After every keyboard eval, release modifiers and run copy/shortcut smoke; inspect key flags and logs for synthetic cleanup triggering AltTab | Partial |
| REL-063 | Duplicate shortcut fires or key-repeat corrupts selection | One tap advances multiple windows, repeated `KEY` events race, or holding shortcut chooses wrong target | Fast-tap, long-hold, and key-repeat matrix; scan logs for duplicate `KEY` transitions and stale release handling | Partial |
| REL-064 | Compositor pause / panel hide atomicity regresses | Fast Alt-Tab does not fire, compositor freezes, or one-frame flicker appears between `hideUi` and focus | Code review for `CGSDisableUpdate`/`CGSReenableUpdate` balance; visual/z-sampler checks for Par↔Par, Par↔Mac, and Mac↔Mac release | Gap/partial |
| REL-065 | Overlay/window levels cover system UI or target windows | Overlay hides Terminal/target, system dialogs appear behind AltTab, or menu bar/Dock is obscured | Verify `overlayMode=false` default; with overlay enabled, check system dialogs, target visibility, Spaces, menu bar, Dock, and overlay teardown | Gap/manual |
| REL-066 | Capture/pre-capture pipeline stalls or crashes | Multiple concurrent captures serialize WindowServer, ScreenCaptureKit prompts, blank Parallels thumbnails, or preview layer crash | Assert single capture pipeline, no SCK for Parallels Coherence, no capture without permission, no AVSampleBufferDisplayLayer path, and bounded capture timing | Gap/partial |
| REL-067 | Eval helpers contaminate app lifecycle/z-order logs | Test helper app launches/quits generate z-review storms or move real windows during measurement | Count `app-launched`/`app-quit` reviews inside bounded eval markers; mark helper storms as contamination unless the scenario is lifecycle-specific | Gap/partial |
| REL-068 | High window count degrades show/focus latency | With ~200 windows, `updatesBeforeShowing`, sort, capture, or z-review exceeds release thresholds | Record window count and timing thresholds; run native and Parallels focus checks on high-window-count desktop and compare to baseline | Partial |
| REL-069 | AX observer or event-registration gaps miss windows/events | New/closed/focused windows do not update because AX observer registration failed or events are dropped after relaunch/wake | Compare running apps + AX windows + CGWindow list + AltTab list; scan observer-registration errors and rerun after app relaunch and wake | Gap/partial |
| REL-070 | Private API/OS-version incompatibility | SkyLight/private symbol missing, call signature changes, or private API returns unsupported errors on current macOS | Startup symbol probe, macOS version record, fallback-path test, and log scan for repeated private-API failures beyond known `CGSOrderWindow err=1000` | Gap |
| REL-071 | Native Command-Tab hotkeys are not restored | System Command-Tab/Shift-Command-Tab stays disabled after AltTab crash, quit, or settings change | Toggle overlapping shortcuts, quit/crash/restart AltTab, verify `setNativeCommandTabEnabled(true)` on exit/start and system Cmd-Tab works | Gap/manual |
| REL-072 | Popup storm contaminates focus/z-order evals | Multiple `UserNotificationCenter` windows or transient `UserNotificationCenter` frontmost causes stale restores, permission dialogs, false failures, or false passes | `ai/eval-popup-storm-guard.sh` preflight/between reps; `ai/eval-log-anomalies.py` fails guard aborts, `UserNotificationCenter` top8 storms, and transient frontmost restores | Covered mechanically; must run before every UI eval |
| REL-073 | Input-capture activity reset blocks outside clicks | After scrolling/navigating the AltTab thumbnail panel, clicks on Chrome/Safari/Terminal do not reach the target app because the outside-click passthrough age was refreshed | Open panel, wait past `inputCapturePassthroughMs`, actively scroll/cycle for >15s, then click a visible app window; verify log shows `outsideUi-stale→hideUi-pass`, target app receives down/up, and panel hides | Covered by code fix; needs manual/eval proof before release |
| REL-074 | Native Cmd+` app-window cycling is stolen by AltTab | With Chrome/Safari front, pressing Cmd+` opens AltTab or focuses Edge Beta/Parallels instead of cycling windows in the current app; logs show `nextWindowShortcut2` | With two Chrome or Safari windows, press Cmd+` and Cmd+Shift+` 3x; verify no `nextWindowShortcut2` hotkey fires when protected and the front app remains the browser | Covered by code fix; needs live restart/log proof |
| REL-075 | Panel ghost-cycles while only hold modifier is down | User holds only Cmd/Option in thumbnail viewer but AltTab rapidly advances through tabs as if Tab/Shift is held | Fast-tap, long-hold, and hold-only matrix; scan for repeated `nextWindowShortcut down/up` without real keyDown repeat; verify artificial repeat only runs for modifier-only shortcuts | Covered by code fix; needs live restart/log proof |
| REL-076 | Minimized window selection does not restore/focus target | Clicking or tabbing to a minimized Messages/Safari/etc. thumbnail hides AltTab but the window stays minimized or not foreground | Minimize Messages/Safari/Terminal test windows; select via hotkey and thumbnail click 3x; verify `MINIMIZE deminimizeBeforeFocus`, target visible z0, front app, and AX focused window | Covered by code fix; needs manual/eval proof |
| REL-077 | Gallery shows only app icons and thumbnails never refresh | Window gallery opens with app icons instead of window thumbnails; `hasThumbnail=false` remains false and `thumbnailUpdateCount=0` after waiting | Run `ai/eval-thumbnail-coverage.sh` 3x with normal thumbnails on; it checks `visibleThumbnailWindowIds` from the live UI, not an arbitrary top-list slice; repeat with a targeted owner if user reports a specific app; fail if visible displayable non-minimized windows stay missing/stale beyond `MAX_STALE_MS`; inspect `/tmp/alttab-thumbnail-coverage-last.json` on failure | Covered for visible-gallery 3x on latest build; content-change freshness still gap |
| REL-078 | Configured Cmd+` AltTab shortcut does not open gallery | User has Cmd as the hold modifier and key-above-tab as the second AltTab shortcut, but pressing/holding Cmd+` does nothing, focuses immediately, or native app cycling runs instead of showing the thumbnail gallery; logs show `focusTarget` on `nextWindowShortcut2-up` before Cmd release | With user shortcuts loaded, restart AltTab and run `ALLOW_SYNTHETIC_HOTKEY_TESTS=1 bash ai/eval-cmd-backtick-gallery.sh` 3x; verify no `not registering nextWindowShortcut2` log, `showPanel` appears, `appIsBeingUsed=true` while held, and no `focusTarget` occurs before hold-modifier release | New issue; fix caches recent modifier state to prevent premature hold-release safety |
| REL-079 | Evals inherit stale shortcut profile and misclassify windows | A previous Cmd+`/profile-2 test leaves `App.shortcutIndex=1`, so later coverage checks use “active app only” and report visible windows as missing/not displayable for `notActiveApp` | Every eval that checks displayability must explicitly `--show=$SHORTCUT_INDEX` on the intended profile, wait for `updatesBeforeShowing`, query state/list, then `--hide`; failure output must include `displayHideReasons` | New eval hygiene issue; `ai/eval-window-coverage.sh` patched |
| REL-080 | Multi-monitor outside click does not reach target app | AltTab/gallery/capture state prevents clicking an app/window on one monitor when another window exists on another monitor; logs may show outside click down passed but up absorbed, or coordinate conversion treats another-screen click as inside UI | With at least two `NSScreen`s, open gallery on each `showOnScreen` mode, wait past `inputCapturePassthroughMs`, click known windows on the other monitor 3x; run `ai/eval-multiscreen-click-routing.sh` and verify both mouse down/up are passed (`outsideUi-stale→hideUi-pass` then `outsideUi-after-pass`), target app fronts, and `appIsBeingUsed=false` | New issue; outside mouse-up now passes through after a stale outside mouse-down pass |
| REL-081 | ScreenCaptureKit thumbnail failures leave icons stale | Logs show `SCStreamErrorDomain Code=-3802 "Stream failed to start"` and gallery thumbnails remain stale/icons despite capture requests | Default SCK off unless explicitly enabled; `ai/eval-thumbnail-coverage.sh` writes an eval marker and `ai/eval-log-anomalies.py` fails any `SCStreamErrorDomain`/`Code=-3802` inside the marked run | Covered mechanically for thumbnail eval; longer capture/perf matrix still required |
| REL-082 | New same-app window opens behind current window | Pressing Cmd+N in Terminal/Safari/etc. creates a new window, but AltTab stale z-order enforcement or same-app ordering leaves the new window behind the current one; logs show `created-window wid=<new>` without matching `focused-window`/frontmost z0 | From a focused app window, press Cmd+N 3x for Terminal and Safari; verify the newly-created window becomes visual z0 within 250ms of first WindowServer appearance, remains top, and becomes the top AltTab entry; separately record app window-creation latency; scan for stale `alttab-focus-intent` enforcement against an older same-pid window after creation | Covered for Terminal 3x; Safari/app matrix still pending |
| REL-083 | AltTab modifier state releases Parallels z guard | After AltTab switches from OneNote/Outlook/other Parallels Coherence to Terminal/Safari, the old Parallels window flashes or reactivates 0.5-2s later; logs show `released stale z-order enforcement by external activation ... key=modifiers=...` for AltTab's own hold/shortcut modifiers or broad `app-created-window` release for a Parallels pid | Run Parallels→Mac 3x with normal modifier release, scan bounded logs for modifier-only external-activation releases from configured AltTab shortcut modifiers, verify post-z0 source reappear count is zero, and rerun a non-AltTab external-hotkey focus eval to prove intentional external activation still cancels stale guards | New issue; code now gates AltTab shortcut modifier-only releases and ignores Parallels app-level created-window noise |
| REL-084 | Parallels target is visually/keyboard unready after AltTab | AltTab+thumbnail click selects OneNote/Outlook, panel hides slowly, `fn+e`/Karabiner remaps do not affect the guest until a manual click; logs show `parHideNow ... ready=false`, delayed `FRONT_MISMATCH`/`PARHIDE restore attempt`, stale external front signal corroborated by AX/Carbon/System Events, or `WINSIDEFG` still naming the previous guest HWND after macOS visual z0/frontPid are correct | Mac→Par and Par→Par thumbnail/select transitions 3x; immediately run a harmless Shift probe and app-specific hotkey smoke when safe; bounded logs must show no `parHideNow ready=false`, target visual z0 + best front process + AX focused window all match before hide, `ax_front_pid`/`carbon_front_pid` match target, no `PARHIDE restore attempt` when `frontmostPid==targetPid`, no click-misroute after hide, and guest `WINSIDEFG` must match the selected Coherence target title/HWND by hide time; correlate Mac `utcMs`, sampler `utc_ms`, and Winside `winMs` for cross-host causality; sampler `ns_front_pid` is warning-only unless corroborated | Current candidate re-enables bounded guest pre-focus (`parGuestPrefocusMaxAgeMs=350`) and replaces slow host `LIST` lookup with guest-side `SETTITLE64`; stale queued Winside SETs must log skip and never fire seconds late; if visual z0 lags but frontmost is correct, keep the panel up and wait; `FRONTMOSTSET` no-window repokes must be generation/z0-gated but not skipped solely because AltTab's own `NSWorkspace` already sees the target front |
| REL-085 | Same-app visual focus differs from keyboard focus | A Terminal/Safari/etc. window is visually top after AltTab/click, but typing goes to a different same-app window; z0 and front pid match target, but AX focused window does not | Z-sampler must record `ax_focused_wid`; every native same-app and native cross-app run must fail when `ax_focus_mismatch_after_z0_samples > 0`; manually click/AltTab among Terminal windows 3x and verify a harmless Shift probe lands in the target | New issue; explicit AX focused-window set plus delayed verifier added, full matrix pending |
| REL-086 | WindowServer same-app clusters are imported as MRU order | After restart/first summon or z-order refresh, all Safari/Terminal/etc. windows appear together at the front of the AltTab gallery even though only one was recently focused; `--detailed-list` mirrors a raw WindowServer same-app block instead of focus history | With several Safari and Terminal windows interleaved by real focus history, restart AltTab, open gallery 3x, and compare `--detailed-list` against recorded focus sequence; fail if raw z-order seeding promotes more than one representative per pid into the MRU prefix | New issue; first-summon `sortByLevel` must seed recently-focused order cluster-safely |
| REL-087 | Visible auxiliary/non-layer-0 windows are missing or unrecoverable | Teams meeting compact view, meeting side panel, floating call control, PiP, or similar visible windows are not in AltTab, and the user cannot recover the associated main window from the gallery | Cross-check `CGWindowListCopyWindowInfo` visible windows on nonzero layers against AX windows and `--detailed-list`; for Teams/Meet/OBS/Parallels, either show the visible auxiliary when it is keyboard-interactive or prove the main window is present, focusable, and searchable | New issue; current Teams compact view was layer 24 and absent while normal Teams windows were displayable |
| REL-088 | Stale focus-event suppression masks external activation | A Karabiner/hyper/manual activation changes front app/window, but AltTab suppresses the AX/NSWorkspace event as post-AltTab noise, then restores or keeps ordering for the stale AltTab target | Trigger external focus during the post-AltTab guard window 3x using exact Karabiner/Parallels commands and manual app focus; bounded logs must show guard release before any restore, no suppressed real `application-focused`/`focused-window` event, and final z/front/AX match the external target | New issue; AX focus/main-window events now release stale enforcement before suppression when they indicate external focus |
| REL-089 | Parallels same-boundary Outlook↔OneNote flashes or raises source clusters | Switching between Parallels Coherence apps such as Outlook Classic and OneNote succeeds eventually, but many source-app windows flash or stay clustered near the top; logs show `[DIAG SAMEAPP] ... Outlook (classic)=7` after target z0, repeated `PARHIDE restore attempt`, unstable top-stack signatures, guest `SETTITLE64` `ERR no-hwnd`, or slow `parHideNow` despite focus completing quickly | Outlook Classic→OneNote and OneNote→Outlook 3x with high-resolution z-sampler; fail if source reappears after target z0, if target-app siblings remain above the pre-focus source divider, if same-boundary `PARHIDE restore attempt` occurs, if `parHideNow stack` is below the required stability window, if guest foreground/title does not match target by hide time, or if panel-open `CAPTURE` refresh includes unblocked thumbnail captures during the handoff; compare Mac `utcMs` with Winside `winMs` when attributing flicker | Current candidate gates gallery hide on target z0/top-stack stability, uses `700ms` same-boundary hide/stack stability, blocks thumbnail capture during focus settle, skips Coherence thumbnails while the panel is open, uses `userGenerated` for Parallels targets, logs concrete top stacks/promotions, coalesces move/resize z-review storms, and normalizes Winside title matching; do not re-enable same-boundary host reasserts or broad unrelated-app cluster repair to chase latency |
| REL-090 | Runtime anomalies are only visible after manual log review | A build looks green because evals pass, but live use immediately logs target/top/focus mismatches, stale delayed probes, Winside errors, popup storms, or click misroutes that no tool fails on | Every dev/install launch must run `ai/monitor-runtime-anomalies.py`; focus transitions must emit `[DIAG ANOMALY]` when current target state disagrees with z0/AX focus after the panel is gone; delayed probes must be generation-gated; release cannot pass with unexplained runtime anomaly counts; if AX focus remains on the target but a same-app sibling becomes z0, the selected target must be repaired rather than dismissed as a dialog | Current candidate adds `[DIAG ANOMALY]`, `[DIAG MONITOR]`, post-build bounded monitoring, target z0/AX invariant checks, stale delayed-probe suppression, bounded anomaly repair, and click-misroute bounds filtering |

## Required Release Checklist

### Preflight

- Confirm one AltTab process only: `pgrep -afil 'AltTab\\.app/Contents/MacOS/AltTab'`.
- Confirm the live process path is `/Applications/AltTab.app/Contents/MacOS/AltTab`, not DerivedData, Trash, a backup app, or an old install.
- Confirm `$ALTTAB_DYLIB_OVERRIDE` points to the candidate dylib in dev mode, and save the candidate cdhash.
- Confirm no active eval tools: `pgrep -afil 'z-order-sampler|eval-.*transition|post-key|post-shift|post-modifier'`.
- Confirm user idle before UI-driving evals: `bash ai/eval-user-idle-guard.sh preflight`; use `ALLOW_ACTIVE_USER_EVALS=1` only for deliberate interactive/manual runs.
- Confirm no old helper apps/processes from evals are still launching/quitting and contaminating lifecycle logs.
- Confirm Hammerspoon state: `pgrep -afil Hammerspoon`; verify it is not startup-enabled if the bug involves hotkeys.
- Confirm Karabiner config target for Outlook Classic: inspect `~/.config/karabiner/karabiner.json` and `/Users/kganjam/bin/focus-parallels-outlook`.
- Confirm no popup storm before testing: `bash ai/eval-popup-storm-guard.sh preflight`; stop on exit `86`.
- Confirm defaults are release-like: `diagnosticsLevel=perf`, heavy trace off, thumbnails on, z fixes on, native experiments off.
- Snapshot `defaults read com.lwouis.alt-tab-macos` and explicitly account for every focus/z-order/capture/overlay/debug override.
- Confirm TCC state only if symptoms suggest permission problems; do not reset TCC routinely.
- Confirm `/tmp/alttab-run.log` is being written by the current PID.
- Confirm each UI-driving eval snapshots the starting top-level window, restores it on clean exit, and skips restoration if the user changes the top-level window during the run.

### Build And Launch

- Run `bash ai/build.sh compile`.
- Run `bash ai/build.sh dev`.
- Verify PID survives for at least 10 seconds with PPID `1`.
- Save dev dylib cdhash.
- Verify no DerivedData/Release/Debug AltTab process survives and no stale LaunchServices instance wins.
- Run current-build log scan from the dev-build marker and fail on any failures.

### Native Focus Matrix

- Run 3x Terminal→Safari with z-sampler and Shift probe.
- Run 3x Safari→Terminal with z-sampler and Shift probe.
- Run 3x Safari window A→Safari window B.
- Run 3x Terminal window A→Terminal window B.
- In every native cross-app run, assert the target app does not fill top-8 after focus (`same_app_top8_after_z0_max <= 1`); in every same-app run, assert no non-target same-app sibling is above the first non-target-app divider after the target reaches z0.
- In every native same-app and native cross-app run, assert AX focused window equals the target after target reaches z0 (`ax_focus_mismatch_after_z0_samples == 0`).
- With multiple windows from the same app, verify restart/first-summon ordering keeps only one representative per app in the MRU prefix and preserves the prior interleaved focus history.
- Inspect code paths for app-level activation and broad AX sibling raises; standard window switching may only focus the selected window.
- Run target depth matrix: immediate previous, index 1, middle, deep.
- Run timing matrix: fast tap, normal tap, long hold, repeated tabs, delayed release.
- Verify final visual z0, front process, AX focused window, and list order all match.
- Verify a filtered/search panel target focuses the selected filtered item and clearing search does not leave a stale target.
- Verify modal dialogs/popups stay above their parent and are not z-restored behind it.
- Verify `Preferences.onlyShowApplications` and windowless-app mode use app activation only in those explicit modes.

### Parallels Coherence Matrix

- Run 3x OneNote→Safari.
- Run 3x Safari→OneNote.
- Run 3x Outlook Classic→Safari.
- Run 3x Safari→Outlook Classic.
- Run 3x Outlook Classic→OneNote and 3x OneNote→Outlook Classic.
- Run 3x Teams→Terminal.
- Run 3x Terminal→Teams.
- Verify no post-z0 flicker, no source reappear, no sibling intrusion, and `parHideNow` readiness.

### External Hotkeys And Tools

- Run Karabiner `fn+o` Outlook Classic external-focus eval 3x.
- Run no-key negative control only when validating the stale-restore detector.
- Trigger external focus during the post-AltTab guard window and verify real AX/NSWorkspace focus events release stale guards instead of being suppressed.
- Verify Hammerspoon is off or explicitly accounted for.
- Verify external focus does not produce `FRONT_MISMATCH ... restoring`.
- Verify regular AltTab does not produce external-key guard release.

### Click And Drag Behavior

- Click target app/window from another app and verify input routes to clicked app at +200ms and +500ms.
- Open AltTab, wait past `inputCapturePassthroughMs`, actively scroll/cycle the thumbnail panel, then click Chrome/Safari/Terminal outside the panel; verify the first outside click passes through and reaches the app.
- Click AltTab thumbnails for native/native, Mac→Par, Par→Mac, same-app multi-window.
- Click a minimized-window thumbnail and verify it deminimizes before focus.
- Open the gallery and verify thumbnails, not just app icons, appear and refresh; run `ai/eval-thumbnail-coverage.sh` and inspect missing/stale rows.
- Drag Teams/Parallels window for at least 5 seconds; verify no full `window-moved-resized` z-order review storm while mouse is down.
- Drag native Safari/Terminal windows; verify no jitter and no stale list order after mouse-up.

### Window Lifecycle

- Create test Safari/Terminal windows, verify ordering after open.
- Create a native save/open dialog and one app popup/sheet; verify dialog/popup remains topmost and usable.
- Verify active meeting/recording windows appear: Teams meeting, Google Meet browser window, and OBS-recorded browser window if present.
- Verify visible auxiliary/non-layer-0 windows such as Teams compact meeting view, floating call controls, and PiP are either intentionally represented or their associated main windows are present and focusable.
- Verify visible Parallels Desktop VM windows appear and are displayable, especially the console `Windows 11` window (`com.parallels.desktop.console`), not only Coherence proxy apps.
- Close only test windows, verify list removes them and z order remains correct.
- Minimize/deminimize test windows, verify ordering and focus.
- Change Spaces/desktops and verify z-order/list order after return.
- Relaunch target apps and verify AX observers are reattached and no running app/window is missing from AltTab.

### Display Topology

- Sleep/wake and lock/unlock.
- External-only → dual display.
- Dual display → laptop-only.
- Laptop-only → external-only.
- Mirroring on/off.
- Verify menu bar, Dock, internal display, active Space, and AltTab overlay.
- Verify OneNote/Outlook/Teams do not span monitors and recover responsiveness.

### Clipboard And Keyboard Safety

- Run Safari toolbar copy test 3x.
- Verify pasteboard matches expected Safari URL.
- Verify no eval sends Enter/Tab/text into Terminal.
- Use Shift-only probes for keyboard focus.
- Verify Chrome/Safari native Cmd+` and Cmd+Shift+` are not intercepted by AltTab unless the shortcut is explicitly reconfigured away from the protected collision.
- Open the thumbnail viewer, release Tab, hold only the hold modifier, and verify selection does not continue cycling.
- Verify modifier flags are released after every keyboard eval and normal shortcuts still work.
- Verify system Command-Tab is enabled after AltTab quit/restart/settings changes.

### Logging, Performance, And Profiling

- Run with default perf logging.
- Run a minimal check with heavy logging off/basic perf only.
- Run a targeted check with thumbnails off.
- Run a targeted check with z fixes off only to isolate regressions, not as a release mode.
- Check `LOGCOST` average/max.
- Check `updatesBeforeShowing`, `show prep`, capture timing, z-review frequency, and app-launch/app-quit review storms against thresholds.
- Record active window count and run at least one high-window-count check before comparing perf claims.
- Use Instruments/Time Profiler when a latency claim remains unexplained by logs.

### History And Code Review

- Mine recent `git log` for bug-fix subjects touching focus, z-order, capture, permissions, event taps, overlays, and build/install before each candidate.
- Review direct uses of `activate`, `activateAllWindows`, `kAXRaiseAction`, `CGSDisableUpdate`, `CGSSetWindowLevel`, `CGSSetWindowAlpha`, private SkyLight calls, event-tap restarts, and global synthetic input.
- Confirm release gates cover every user-observed issue from the current session and every relevant historical fix that could regress.
- Confirm `experiments/release-risk-code-review.md` maps every touched risky code area to release issues and validation artifacts.
- Add a new `REL-*` row before accepting a fix if a bug class is not represented here.

### Manual Review

- Read bounded `/tmp/alttab-run.log` regions.
- Read `*.zscan.txt`.
- Read `*.logscan.txt`.
- Generate LLM prompt review and inspect whether mechanical passes match human-observed behavior.
- Record results in `experiments/notebook.md`.

## Coverage Audit Against Current Code

| Area | Current Tooling | Status |
| --- | --- | --- |
| Compile/build sanity | `ai/build.sh compile`, `ai/build.sh dev` | Covered |
| Dev process survival | `ai/build.sh dev` LaunchServices path | Covered for latest run |
| Current runtime log anomalies | `ai/eval-log-anomalies.py` | Covered for latest targeted runs; full release matrix still required |
| User-active eval guard | `ai/eval-user-idle-guard.sh` wired into UI-driving evals | Covered mechanically; latest rerun stopped instead of contaminating evidence while user input was active |
| Native z/focus exact checks | `ai/eval-select-transition.sh`, `ai/z-order-sampler.swift` | Partial; Terminal↔Safari and same-app targeted runs passed, depth/timing matrix still required |
| Rapid overlap | `ai/eval-rapid-overlap-transition.sh` | Partial; not rerun after latest code |
| Parallels z/flicker | `ai/eval-focus-regression-suite.sh`, z-sampler | Partial; Terminal↔Parallels Desktop targeted runs passed, Coherence app matrix still required |
| Karabiner Outlook Classic | `ai/eval-external-launch-transition.sh` | Partial; not rerun after latest code |
| Copy/paste | `ai/eval-copy-after-focus.sh` | Covered mechanically; Safari toolbar copy passed 3/3 after latest code |
| Prompt review | `ai/eval-prompt-review.sh`, `ai/prompts/focus-log-review.md` | Covered mechanically; not rerun after latest code |
| Static release-risk code review | `ai/eval-release-risk-static.sh`, `experiments/release-risk-code-review.md` | Covered mechanically for known code-review footguns |
| Drag jitter | Code path exists in `Windows.deferZOrderReviewIfDragging`; no dedicated eval | Partial/gap |
| Thumbnail freshness | No dedicated changed-content freshness eval | Gap |
| Gallery icon-only thumbnails | `ai/eval-thumbnail-coverage.sh` checks `hasThumbnail`, `thumbnailAgeMs`, and `thumbnailUpdateCount` while gallery is open, then scans the marked log window for SCK errors | Covered for latest visible-gallery 3x; content-change freshness still needs dedicated proof |
| Thumbnail-click focus | No dedicated thumbnail-click automation | Gap |
| Parallels target keyboard readiness | Parallels target z/front/AX readiness plus Karabiner hotkey smoke | New; needs live 3x validation after latest code |
| Display topology | No automated topology matrix | Gap/manual |
| Hammerspoon startup/interference | No checker | Gap/manual |
| Spaces/desktops | No full automated Space matrix | Gap |
| Window lifecycle open/close/minimize | Partial lifecycle logs; no complete release matrix | Partial/gap |
| Modifier-only Parallels bounce | Parallels→Mac z-sampler plus bounded log scan for `key=modifiers=` guard release | Covered by code fix; needs live 3x validation |
| Permission dialogs/TCC | `ai/tcc.sh`, log checks for stuck popup | Partial |
| Screen Recording timeout loop | `SystemPermissions` preflight/backoff; bounded log scan | Covered for immediate restart; longer release run still required |
| Popup storm guard | `ai/eval-popup-storm-guard.sh`, `ai/eval-log-anomalies.py` | Covered mechanically for UserNotificationCenter storms and transient-frontmost restores |
| Outside-click passthrough after panel activity | Manual/log check for `outsideUi-stale→hideUi-pass`; no dedicated automation yet | Partial/gap |
| Main-thread lock contention | Instruments/profile notes only | Partial |
| Multiple instances / wrong binary path | `pgrep`, live path/cdhash checks, build-script process cleanup | Partial |
| Restart loops | Restart lock logs and process-count checks | Partial/gap |
| Stale defaults | Manual defaults snapshot | Partial |
| Dialogs/popups | No complete dialog/popup automation | Gap |
| Hidden/bugged windows | `--detailed-list` now exposes displayability; no broad app matrix | Partial/gap |
| Sleep/wake | `SleepWakeEvents` exists; no current release matrix | Gap/manual |
| Search/filter selection | No dedicated focus/z-order eval | Gap |
| Windowless/app-only mode | Code path exists; not in current regression suite | Gap |
| Modifier stuck state | Copy probe releases modifiers; no general modifier-state checker | Partial |
| Double shortcut fires | Historical debounce; no current fast-tap/key-repeat suite | Partial/gap |
| Compositor pause/overlay levels | Code/history review only; no complete visual matrix | Gap/manual |
| Capture pipeline stalls/crashes | Capture toggles exist; no current capture stress matrix | Gap/partial |
| Eval lifecycle contamination | Log review can see helper storms; no automatic threshold | Gap/partial |
| High-window-count performance | Perf logs include count; no enforced threshold | Gap/partial |
| AX observer coverage | Partial list/window coverage tools; no observer-health suite | Gap/partial |
| Private API compatibility | No current symbol/fallback matrix | Gap |
| Native Command-Tab restore | Startup/quit code exists; no manual proof on candidate | Gap/manual |
| Current code release readiness | Targeted subset passed, but dirty tree and full-matrix gaps remain | Not releasable yet |

## Current Release Blockers

- Full regression suite has not been rerun after the latest native-focus, drag, external-key, and dev-launch changes.
- Latest broad suite was contaminated by `UserNotificationCenter` storm symptoms; rerun only after the popup guard is clean.
- Outside-click passthrough after active panel scrolling/cycling needs explicit 3x manual/log validation on the candidate build.
- Display topology, sleep/wake, drag jitter, thumbnail freshness, thumbnail-click, Hammerspoon, Spaces, dialogs/popups, search/filter, app-only/windowless mode, Command-Tab restore, and high-window-count perf checks remain incomplete.
- Working tree is dirty with many code and eval changes.
