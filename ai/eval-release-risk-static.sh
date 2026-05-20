#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import re
import sys

failures: list[str] = []

def read(path: str) -> str:
    return Path(path).read_text()

windows = read("src/logic/Windows.swift")
window = read("src/logic/Window.swift")
agents = read("AGENTS.md")
monitor = read("experiments/release-issue-monitor.md")
risks = read("experiments/release-risk-code-review.md")
select_eval = read("ai/eval-select-transition.sh")

for forbidden in [
    "restoreNativeTargetSiblingOrderForFocus",
    "restoreNativeExpectedSiblingOrderForFocus",
    "restoreNativeExpectedSiblingOrderImmediately",
    "restoreNativeTargetSiblingOrder(",
    "restoreNativeExpectedSiblingOrder(",
    "focusSpecificWindowViaAx",
    "raiseSpecificWindowViaAx",
]:
    if forbidden in windows:
        failures.append(f"forbidden risky helper still present: {forbidden}")

if "intrusive sibling" not in windows:
    failures.append("z-order restore no longer documents/scopes intrusive sibling repair")
if "place #\\(" in windows or "AX full-stack restore" in windows:
    failures.append("full-stack z-order restore text appears to have returned")

fast_start = windows.find("private static func fastRepairTargetZOrder")
fast_end = windows.find("/// Check that the most recent target", fast_start)
fast_repair = windows[fast_start:fast_end] if fast_start >= 0 and fast_end > fast_start else ""
if not fast_repair:
    failures.append("fastRepairTargetZOrder not found")
elif "if targetIsPar, let window" not in fast_repair:
    failures.append("fast z repair AX path is not gated to Parallels")

enforce_start = windows.find("private static func enforceZOrder()")
enforce_end = windows.find("private static func queueAxRecovery", enforce_start)
enforce = windows[enforce_start:enforce_end] if enforce_start >= 0 and enforce_end > enforce_start else ""
if not enforce:
    failures.append("enforceZOrder block not found")
elif "window.application.isParallelsCoherence" not in enforce:
    failures.append("enforceZOrder can queue AX recovery without Parallels gate")

window_code_lines = [line for line in window.splitlines() if "activate(options: .activateAllWindows)" in line and not line.strip().startswith("///")]
activate_all_windows = len(window_code_lines)
if activate_all_windows != 2:
    failures.append(f"expected exactly 2 activateAllWindows calls in Window.swift windowless/app-only branch, found {activate_all_windows}")
for path in ["src/logic/Windows.swift", "src/ui/App.swift", "src/logic/events/AccessibilityEvents.swift"]:
    if "activate(options: .activateAllWindows)" in read(path):
        failures.append(f"activateAllWindows present outside Window.swift: {path}")

required_docs = {
    "AGENTS.md": "experiments/release-risk-code-review.md",
    "experiments/release-issue-monitor.md": "experiments/release-risk-code-review.md",
    "experiments/release-risk-code-review.md": "Current Code Review Fixes",
    "ai/eval-select-transition.sh": "MAX_Z0_MS",
}
contents = {
    "AGENTS.md": agents,
    "experiments/release-issue-monitor.md": monitor,
    "experiments/release-risk-code-review.md": risks,
    "ai/eval-select-transition.sh": select_eval,
}
for path, needle in required_docs.items():
    if needle not in contents[path]:
        failures.append(f"{path} missing required marker: {needle}")

issue_ids = [m.group(1) for m in re.finditer(r"^\| (REL-\d{3}) \|", monitor, re.MULTILINE)]
if len(issue_ids) < 71:
    failures.append(f"release issue monitor unexpectedly small: {len(issue_ids)} rows")
for index, issue_id in enumerate(issue_ids, start=1):
    expected = f"REL-{index:03d}"
    if issue_id != expected:
        failures.append(f"release issue sequence mismatch at {expected}: saw {issue_id}")
        break

if failures:
    print("release-risk-static: FAIL")
    for failure in failures:
        print(f"- {failure}")
    sys.exit(1)
print("release-risk-static: PASS")
PY
