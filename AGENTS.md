# macOS development
- Don't use xcode directly to develop
- Use pure swift 5.8 code to make the app. No interface builder. No SwiftUI.
- Aim for compact code. Within methods, don't have groups of statements separated with newlines. No inline comments for simple code. Instead, split statements into sub-methods.
- Use guard closes as much as possible to separate the happy-path under them
- Organize source files into folders. Folders should group files that change together, at the same pace (e.g. one feature)
- Favor low latency and responsiveness. Reuse objects, avoid wasting memory or I/O.

# Workflow
- Copy commands from ai/build.sh and run them, to confirm compilation works after you're done with implementing a change

# Per-window focus behavior (NEVER REGRESS)
- AltTab must focus only the *selected* window of an app, not all of its windows. This is the entire reason AltTab exists vs. system Cmd-Tab.
- The standard macOS path in `Window.focus()` uses `_SLPSSetFrontProcessWithOptions(&psn, cgWindowId, .userGenerated)` followed by `axUiElement.focusWindow()`. Do not replace this with an app-level activate, and do not split the SLPS / makeKeyWindow / AX-focusWindow sequence in a way that briefly exposes all-windows-up state — even a flash is a regression.
- `NSRunningApplication.activate(options: .activateAllWindows)` is reserved for the windowless-apps and `Preferences.onlyShowApplications` branches only. Never use it on the standard window-switch path.
- The `[DIAG SAMEAPP]` log line in `/tmp/alttab-run.log` fires when multiple windows of the same app appear in top-8 z-order after a focus — that is the regression signal. Investigate every occurrence.
