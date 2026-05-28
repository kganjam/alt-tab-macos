#!/usr/bin/env python3
import argparse
import re
import time
from pathlib import Path


PATTERNS = [
    ("ANOMALY", "FAIL", re.compile(r"\[DIAG ANOMALY\]")),
    ("FRONT_RESTORE", "FAIL", re.compile(r"\[DIAG FRONT_MISMATCH\].*(?:restoring|restore attempt)")),
    ("PAR_READY_FALSE", "FAIL", re.compile(r"parHideNow .*ready=false")),
    ("PAR_GUEST_NOT_READY", "FAIL", re.compile(r"parHideNow .* guest=false")),
    ("CLICK_MISROUTE", "FAIL", re.compile(r"\[DIAG CLICKMISROUTE\]|\[DIAG CLICKAFTER\].*MISMATCH")),
    ("WINSIDE_ERROR", "FAIL", re.compile(r"\[DIAG WINSIDE.*(?:\bERR\b|bad response|no response|no-hwnd)", re.I)),
    ("POPUP_STORM", "FAIL", re.compile(r"UserNotificationCenter.*(?:top8|frontmost|storm)", re.I)),
    ("PERMISSION_PROMPT", "FAIL", re.compile(r"(?:TCC|AX|screen recording|accessibility).*(?:permission|prompt|denied)|permission prompt", re.I)),
    ("SOURCE_TARGET_ORDER", "FAIL", re.compile(r"\[DIAG ORDER\].*source-target-focus")),
    ("STALE_MOUSE_RELEASE", "FAIL", re.compile(r"\[DIAG PERF\].*\bfocusTarget\s+\+[0-9.]+ms \[mouseClick\]")),
    ("SAMEAPP", "WARN", re.compile(r"\[DIAG SAMEAPP\]")),
    ("ZPROMOTE", "WARN", re.compile(r"\[DIAG ZPROMOTE\]")),
]


def parse_args():
    parser = argparse.ArgumentParser(description="Bounded realtime AltTab anomaly monitor")
    parser.add_argument("--log", default="/tmp/alttab-run.log")
    parser.add_argument("--duration", type=float, default=20.0)
    parser.add_argument("--from-end", action="store_true", default=True)
    parser.add_argument("--quiet", action="store_true")
    return parser.parse_args()


def follow(path: Path, duration: float, from_end: bool):
    deadline = time.monotonic() + duration
    with path.open("r", errors="replace") as handle:
        if from_end:
            handle.seek(0, 2)
        while time.monotonic() < deadline:
            line = handle.readline()
            if line:
                yield line.rstrip("\n")
            else:
                time.sleep(0.05)


def main():
    args = parse_args()
    severities = {name: severity for name, severity, _ in PATTERNS}
    counts = {name: 0 for name, _, _ in PATTERNS}
    seen = []
    for line in follow(Path(args.log), args.duration, args.from_end):
        for name, severity, pattern in PATTERNS:
            if pattern.search(line):
                counts[name] += 1
                seen.append((name, severity, line))
                if not args.quiet:
                    print(f"runtime-anomaly {severity} {name}: {line}", flush=True)
                break
    fail_total = sum(count for name, count in counts.items() if severities[name] == "FAIL")
    warn_total = sum(count for name, count in counts.items() if severities[name] == "WARN")
    print("runtime-anomaly-summary " + " ".join(f"{name}={count}" for name, count in counts.items()) + f" fail_total={fail_total} warn_total={warn_total} total={fail_total}")
    return 1 if fail_total else 0


if __name__ == "__main__":
    raise SystemExit(main())
