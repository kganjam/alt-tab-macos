#!/usr/bin/env python3
import argparse
import re
import time
from pathlib import Path


PATTERNS = [
    ("ANOMALY", re.compile(r"\[DIAG ANOMALY\]")),
    ("FRONT_RESTORE", re.compile(r"\[DIAG FRONT_MISMATCH\].*(?:restoring|restore attempt)")),
    ("PAR_READY_FALSE", re.compile(r"parHideNow .*ready=false")),
    ("CLICK_MISROUTE", re.compile(r"\[DIAG CLICKMISROUTE\]|\[DIAG CLICKAFTER\].*MISMATCH")),
    ("WINSIDE_ERROR", re.compile(r"\[DIAG WINSIDE.*(?:\bERR\b|bad response|no response|no-hwnd)", re.I)),
    ("POPUP_STORM", re.compile(r"UserNotificationCenter.*(?:top8|frontmost|storm)", re.I)),
    ("PERMISSION_PROMPT", re.compile(r"permission|accessibility|screen recording", re.I)),
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
    counts = {name: 0 for name, _ in PATTERNS}
    seen = []
    for line in follow(Path(args.log), args.duration, args.from_end):
        for name, pattern in PATTERNS:
            if pattern.search(line):
                counts[name] += 1
                seen.append((name, line))
                if not args.quiet:
                    print(f"runtime-anomaly {name}: {line}", flush=True)
                break
    total = sum(counts.values())
    print("runtime-anomaly-summary " + " ".join(f"{name}={count}" for name, count in counts.items()) + f" total={total}")
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
