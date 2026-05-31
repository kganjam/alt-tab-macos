<div align = center>

# AltTab

[![Screenshot](docs/public/demo/frontpage.jpg)](docs/public/demo/frontpage.jpg)

**AltTab** brings the power of Windows alt-tab to macOS

[Official website](https://alt-tab.app/)<br/><sub>15K stars</sub> | [Download](https://github.com/lwouis/alt-tab-macos/releases/download/v10.12.0/AltTab-10.12.0.zip)<br/><sub>7.4M downloads</sub>
-|-

<div align="right">
  <p>Project supported by</p>
  <a href="https://jb.gg/OpenSource">
    <img src="docs/public/demo/jetbrains.svg" alt="Jetbrains" width="149" height="32">
  </a>
</div>

</div>

## Development (this fork)

This is a customized fork of [lwouis/alt-tab-macos](https://github.com/lwouis/alt-tab-macos)
with heavy work on per-window focus, z-order/recency stability across Parallels
Coherence, and a background thumbnail-capture pipeline that stays within macOS's
per-client IOSurface budget. All work lives on branch `parallels-coherence-focus-fix`
(mirrored to `master` on the fork).

Bootstrap docs (read in this order):
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — subsystem & source map; the thumbnail
  capture / IOSurface-leak design; build/test/profiling; the eval harness.
- **[AGENTS.md](AGENTS.md)** — working rules, the `ai/build.sh` dev loop, code-signing/TCC,
  the per-window-focus + IOSurface-budget invariants, and the required regression checks.
- **[UPSTREAM.md](UPSTREAM.md)** — how to pull changes from the original project.
- `experiments/release-issue-monitor.md` — the known-regression release gate (REL-001…).
- `experiments/release-risk-code-review.md`, `experiments/focus-hypotheses.md`,
  `experiments/notebook.md` — risk map, hypotheses/evidence, and run history.

Quick start:
- Build / run: `bash ai/build.sh compile` (or `dev` to launch; see AGENTS.md).
- Unit tests: `xcodebuild test -workspace alt-tab-macos.xcworkspace -scheme Test -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
- Runtime logs: `/tmp/alttab/latest.log` (`defaults write com.lwouis.alt-tab-macos diagnosticsLevel perf` for timing + `THUMBCACHE` leak counters).
