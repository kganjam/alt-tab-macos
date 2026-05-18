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
  When adding timing logs, include millisecond-or-better timestamps and
  account for logging overhead if it affects the claim.
- For UI/focus/z-order validation, run each check at least 3 times before
  trusting it. The user may still be active during unattended runs; real
  clicks, typing, display changes, or app activity can interfere with
  measurements. Treat any run with user activity or unexpected external
  events as contaminated, note it, and rerun rather than optimizing around
  a single sample.
- Do not run synthetic global-hotkey tests against the user's live
  Terminal/session. They can route keystrokes to the active shell when a
  switch lands in Terminal. Use exact-focus probes first; only run
  hotkey-path probes on an isolated test desktop/window with explicit
  opt-in environment flags.
- To verify keyboard focus without typing into the target, post Shift
  down/up only. It exercises focus delivery without inserting text or
  sending Enter/Tab into the user's active Terminal.

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
