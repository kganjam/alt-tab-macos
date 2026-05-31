# Upstream sync workflow

This fork (`origin` = `github.com/kganjam/alt-tab-macos`) is the working repo for
all ongoing development. We still want to pull fixes from the original project
(`upstream` = `github.com/lwouis/alt-tab-macos`). This doc is the process.

## Remotes & branches

- `origin` — your fork. `parallels-coherence-focus-fix` is the **working
  mainline** (all custom work); `master` mirrors it after each landing.
- `upstream` — lwouis/alt-tab-macos. Its `master` is the original project.

If `upstream` is ever missing: `git remote add upstream https://github.com/lwouis/alt-tab-macos.git`

## Pull / assess (safe, read-only)

```bash
git fetch upstream --no-tags
# how far each side has diverged from the common fork point:
base=$(git merge-base HEAD upstream/master)
git rev-list --count "$base"..upstream/master   # commits upstream added
git rev-list --count upstream/master..HEAD       # our commits
git log --oneline "$base"..upstream/master        # what upstream changed
# dry-run the merge WITHOUT touching the working tree (git 2.38+):
git merge-tree --write-tree --name-only HEAD upstream/master | sed -n '2,$p' \
  | grep -vE '^(Pods|vendor|.*Sparkle)/'          # real source/config conflicts
```

## Current divergence (assessed 2026-05-31)

- Upstream is **14 commits** ahead of our fork point; our line is **140** ahead.
- Upstream's `11.0.0` ("**alt-tab pro**", commit `9147a4a8`) **reorganized the
  entire `src/` tree** (`src/logic/Window.swift` → `src/switcher/state/Window.swift`,
  new `src/macos/`, `src/events/`, etc.) plus a Sparkle/vendoring refactor. Git
  rename-detects most files, but there are **~19 content conflicts** in our app
  code/config (`src/App.swift`, `src/switcher/state/Window{,s}.swift`,
  `src/events/WindowCaptureEvents.swift`, `src/macos/SystemPermissions.swift`,
  `Logger.swift`, `Menubar.swift`, `UsageStats.swift`, `Info.plist`,
  `project.pbxproj`, `ai/build.sh`, `AGENTS.md`, `unit-tests/Mocks.swift`, …).
- **Therefore a full merge is a deliberate, file-by-file effort** (resolve the
  reorg + the alt-tab-pro feature) followed by the **full eval suite** — not a
  blind `git merge`. Do it on a dedicated branch, never directly on the working
  mainline or `master`.

### Recommended full-merge procedure (when undertaken)

1. `git switch -c upstream-merge-<date> parallels-coherence-focus-fix`
2. `git merge upstream/master` (expect the conflicts above).
3. Resolve conflicts **reading both sides** (our customizations vs upstream's
   reorg + alt-tab-pro). Never `-X ours/theirs` wholesale on source files.
4. `grep -rn '<<<<<<<\|=======\|>>>>>>>' src/` before committing.
5. `bash ai/build.sh compile` + `xcodebuild test -scheme Test`.
6. Run the full eval suite (`AGENTS.md` "durable regression checks" +
   `experiments/release-issue-monitor.md`). Per-window focus + IOSurface budget
   are the highest-risk regressions.
7. Only then fast-forward `parallels-coherence-focus-fix` / `master`.

## Directly-relevant upstream fixes (port, don't wait for the full merge)

Because paths/code diverged, port the *intent* manually rather than cherry-pick.

| Upstream commit | What | Status in this fork |
| --- | --- | --- |
| `f4a54c8f` rare crash capturing thumbnails | lock `cachedSCWindows`; snapshot Window state on main before the screenshots queue | **Ported** (commits `13e532ed`, `3db59bf8`) — and we found/fixed it independently |
| `04346790` electron hidden windows | `addWindowlessWindowIfNeeded` skips when only invisible windows exist (`!$0.isInvisible`) | **Backlog** — needs an `isInvisible` equivalent in our `Window` |
| `3a48a13c` cmd key stuck after switching | modifier-release edge case | **Backlog** — review against our keyboard-events path |
| `49778089` crash assigning arrow-key shortcuts | shortcut recorder guard | **Backlog** |
| `007edc62` very rare crash on quit | teardown ordering | **Backlog** |

## Pushing upstream's tags/releases

We do **not** track upstream tags (`--no-tags`) to avoid polluting the fork's
release/appcast flow. Our releases are driven from this fork's own versioning.
