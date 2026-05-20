# macOS development
- Don't use xcode directly to develop
- Use pure swift 5.8 code to make the app. No interface builder. No SwiftUI.
- Aim for compact code. Within methods, don't have groups of statements separated with newlines. No inline comments for simple code. Instead, split statements into sub-methods.
- Use guard closes as much as possible to separate the happy-path under them
- Organize source files into folders. Folders should group files that change together, at the same pace (e.g. one feature)
- Favor low latency and responsiveness. Reuse objects, avoid wasting memory or I/O.

# Build / install / dev iteration

Use `bash ai/build.sh {compile|dev|install}`. Three modes, one script:

- `bash ai/build.sh compile` — Debug build to DerivedData. Verifies code
  compiles; no signing, no install, no run. Use after every code edit
  to confirm syntax/types are clean. Fast.

- `bash ai/build.sh dev` — Builds *only* `AltTabCore.dylib` (Release),
  signs it, drops it at `dev/AltTabCore.dylib`, then launches the
  *installed* shim binary at `/Applications/AltTab.app/Contents/MacOS/AltTab`
  with `$ALTTAB_DYLIB_OVERRIDE` pointing at the new dylib. The installed
  bundle is **never modified**, so its code-signing seal stays intact
  and TCC permissions persist. Use this for every iteration where you
  need to actually run AltTab. Doesn't trigger Accessibility/Screen
  Recording prompts.

- `bash ai/build.sh install` — Full bundle install. Builds Release as a
  dylib, places the prebuilt shim at `Contents/MacOS/AltTab`, signs
  bottom-up (each nested dylib/framework, then `--deep --force` on the
  bundle with the AltTab entitlements), atomically replaces
  `/Applications/AltTab.app` via `ditto`+`mv`. **Will trigger TCC
  re-grant prompts.** Use only when `shim/main.c`, Pods, framework deps,
  or entitlements change — rare.

# Working notes and accessory docs

- Before changing focus, z-order, Alt-Tab latency, Parallels Coherence,
  or display-transition behavior, read `experiments/focus-hypotheses.md`.
  It is the current claims/hypotheses/evidence log. Update it whenever
  you prove, disprove, or materially refine a hypothesis; do not repeat
  an invalidated approach unless you add new evidence explaining why it
  should behave differently now.
- `experiments/notebook.md` is the chronological experiment notebook.
  Use it for long-form run history, profiler summaries, and design notes.
  Keep the hypothesis page concise; put verbose run narratives here.
- `experiments/release-issue-monitor.md` is the release-gate checklist of
  every observed focus, z-order, performance, display, input, thumbnail,
  permission, and eval-harness regression class. Before claiming a build is
  good or releasable, check coverage against this file and update the
  current-build audit if new failures or gaps are found.
- `experiments/release-risk-code-review.md` maps release issues to risky
  code areas. Update it when code review finds a new hotspot or when a
  hotspot is fixed, tested, or intentionally left as a residual risk.
- Before passing a build, review recent `git log`, current diffs, local
  experiment docs, and bounded `/tmp/alttab-run.log` regions for bug classes
  not yet represented in `experiments/release-issue-monitor.md`. Add new
  `REL-*` entries first; do not rely on memory or a single clean eval.
- Missing-window checks must compare WindowServer-visible windows against
  AltTab `--detailed-list` displayability. Include Parallels Desktop console
  windows as well as Coherence apps, Teams/Meet/OBS meeting windows.
- `ai/build.sh` is the only supported build/install/dev loop. Use
  `compile` after edits, `dev` for TCC-safe runtime tests, and `install`
  only for rare full bundle/signing changes.
- `ai/profile.sh` contains profiling helpers for Time Profiler / system
  tracing. Prefer it when latency claims need real profiler evidence.
- `ai/run.sh` is a lightweight local run helper for development workflows.
- `ai/tcc.sh` inspects or repairs Accessibility/Screen Recording grants.
  Use it only when TCC state is part of the problem; don't reset TCC as
  a routine troubleshooting step.
- `/tmp/alttab-run.log` is the main runtime diagnostic stream. Use
  `diagnosticsLevel` defaults (`perf`, `trace`, etc.) to control detail.
  When adding timing logs, include millisecond-or-better comparable UTC
  epoch timestamps: Mac diagnostics should include `utcMs=...`, Windows/
  Winside helper responses should include `winMs=...`. Account for logging
  overhead if it affects the claim.
- For UI/focus/z-order validation, run each check at least 3 times before
  trusting it. The user may still be active during unattended runs; real
  clicks, typing, display changes, or app activity can interfere with
  measurements. Treat any run with user activity or unexpected external
  events as contaminated, note it, and rerun rather than optimizing around
  a single sample. UI-driving evals must run `ai/eval-user-idle-guard.sh`
  first unless explicitly overridden with `ALLOW_ACTIVE_USER_EVALS=1`.
- UI-driving experiments must snapshot the starting top-level app/window and
  return AltTab/the desktop to that state before exiting. If the user
  intervenes and changes the top-level window during the run, stop restoring,
  mark the run contaminated, and leave the user's chosen state alone.
- After any change to focus, z-order, recency, input capture, thumbnails,
  Parallels Coherence, or display-transition behavior, run the durable
  regression checks before claiming success:
  - Every `bash ai/build.sh dev`/`install` run performs a bounded
    `ai/monitor-runtime-anomalies.py` pass after launch unless
    `ALTTAB_POST_BUILD_MONITOR_SECONDS=0`. Treat any `[DIAG ANOMALY]`,
    front-restore, click-misroute, guest-focus error, permission prompt, or
    popup-storm match as a failed build that must be explained or fixed.
  - `bash ai/eval-popup-storm-guard.sh <context>` before and between UI
    evals. If it exits `86`, stop testing immediately; the desktop is
    contaminated by a UserNotificationCenter popup storm.
  - `bash ai/eval-focus-regression-suite.sh` for the full panel/z-order,
    copy, Parallels, rapid-overlap, and log-anomaly matrix.
  - `SIMULATE_EXTERNAL_KEY=1 FAIL_KEY_EVENTS=0 SOURCE_APP=Terminal TARGET_OWNER="Outlook (classic)" LAUNCH_COMMAND="/Users/kganjam/bin/focus-parallels-outlook" bash ai/eval-external-launch-transition.sh`
    for the Karabiner `fn+o` → Parallels Outlook Classic external-focus path.
    The no-key control should still reproduce stale restore if the external
    keyboard-release path is not exercised; use it only as a negative control.
  - `bash ai/eval-rapid-overlap-transition.sh` when iterating specifically
    on stale activation, rapid Alt-Tab, or Coherence handoff issues.
  - `python3 ai/eval-log-anomalies.py --marker <MARKER> --end-marker "=== EVAL END MARKER: <MARKER> ===" --strict` on the bounded log region for any custom/manual experiment.
- For every focus/z-order change, also check
  `experiments/release-issue-monitor.md` and explicitly account for all
  `FAIL`, `PARTIAL`, and `Gap` rows relevant to the change. A change that
  fixes latency but causes app-wide activation or same-app sibling raising
  is a regression and must not be accepted.
- Per-window focus is a hard gate: standard AltTab switching must not bring
  every window of the selected app forward. Same-app evals must verify the
  selected target is z0 and non-target siblings are not promoted above
  unrelated apps after the target reaches z0.
- Treat log anomalies as test failures unless you can explain them with
  evidence. Important anomaly classes include stale `app-activated` or
  `focused-window` events after a newer target, `parHideNow` timeout or
  `ready=false`, slow `updatesBeforeShowing`/`show prep`, `[DIAG SAMEAPP]`,
  input-capture watchdogs, missing end markers, app restarts after a marker,
  mouse contamination, popup-storm guard aborts, transient UserNotificationCenter
  frontmost restores, stuck permission-popup flushing, and any unsafe native
  focus experiment path (`native level pin`, `nativeMultiWindowRepoke`,
  `z0ActivationClick`).
- For non-brittle qualitative review, generate a prompt with
  `bash ai/eval-prompt-review.sh <MARKER> [artifacts...]` and have Codex
  or a subagent review the logs/artifacts against
  `ai/prompts/focus-log-review.md`. Include `*.zscan.txt`, `*.logscan.txt`,
  and summary artifacts. This is required for focus/z-order changes that
  pass mechanical checks but still look or feel wrong.
- Do not run synthetic global-hotkey tests against the user's live
  Terminal/session. They can route keystrokes to the active shell when a
  switch lands in Terminal. Use exact-focus probes first; only run
  hotkey-path probes on an isolated test desktop/window with explicit
  opt-in environment flags.
- To verify keyboard focus without typing into the target, post Shift
  down/up only. It exercises focus delivery without inserting text or
  sending Enter/Tab into the user's active Terminal.
- Do not re-enable automatic stuck-permission-popup flushing casually.
  `flushStuckAuthPopupsThreshold=0` is the safe default; enabling it can
  create repeated UserNotificationCenter/usernotificationsd kill loops if
  TCC is unstable.

# Bundle architecture

The installed bundle is **shim + dylib**:
- `Contents/MacOS/AltTab` is a tiny C shim (`shim/main.c`, prebuilt
  binary checked in at `shim/AltTab-shim`). Its only job: read
  `$ALTTAB_DYLIB_OVERRIDE` (or fall back to bundle path), `dlopen` the
  dylib, `dlsym("alt_tab_main")`, call it.
- `Contents/Frameworks/AltTabCore.dylib` is the actual Swift app
  (everything in `src/`), built with `MACH_O_TYPE=mh_dylib`.
- `src/main.swift` exports the entry point via `@_cdecl("alt_tab_main")`.

# Code signing & TCC (READ BEFORE TOUCHING ai/build.sh)

macOS TCC validates the **entire bundle seal** at every permission
check (`SecCodeCheckValidityWithErrors`), not just the executable cdhash
or the csreq predicate. If the seal is broken (e.g. dylib bytes don't
match the hash recorded in `_CodeSignature/CodeResources`), tccd
flips `auth_value` 2→0 and the user gets re-prompted.

Rules to keep TCC grants stable:
- The `Local Self-Signed` cert leaf hash must stay constant across
  rebuilds (`c483b2cf665699cf9467eb96a0c88fce7d7c2036`). Don't
  regenerate the cert.
- `install` mode signs **bottom-up** (nested items first, then bundle
  with `--deep`) so `CodeResources` is regenerated and the seal is
  internally consistent.
- Atomic install via `ditto` to a sibling path then `mv`. **Never
  overwrite individual files inside the live bundle** — the kernel's
  vnode cdhash cache gets corrupted (Apple DTS Quinn, devforums #781548).
- `dev` mode never modifies the installed bundle, so the seal stays
  intact and TCC isn't touched.

If you need to think harder about this, see memory note
`project_alttab_tcc_seal.md`.

# Per-window focus behavior (NEVER REGRESS)
- AltTab must focus only the *selected* window of an app, not all of its windows. This is the entire reason AltTab exists vs. system Cmd-Tab.
- The standard macOS path in `Window.focus()` uses `_SLPSSetFrontProcessWithOptions(&psn, cgWindowId, .userGenerated)` followed by `axUiElement.focusWindow()`. Do not replace this with an app-level activate, and do not split the SLPS / makeKeyWindow / AX-focusWindow sequence in a way that briefly exposes all-windows-up state — even a flash is a regression.
- `NSRunningApplication.activate(options: .activateAllWindows)` is reserved for the windowless-apps and `Preferences.onlyShowApplications` branches only. Never use it on the standard window-switch path.
- The `[DIAG SAMEAPP]` log line in `/tmp/alttab-run.log` fires when multiple windows of the same app appear in top-8 z-order after a focus — that is the regression signal. Investigate every occurrence.
