#!/usr/bin/env python3
from __future__ import annotations
import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

@dataclass
class Issue:
    severity: str
    t_ms: float | None
    kind: str
    message: str
    line: str

def parse_args():
    p = argparse.ArgumentParser(description="Scan AltTab logs for focus/z-order/perf anomalies after an eval marker")
    p.add_argument("--log", default="/tmp/alttab-run.log")
    p.add_argument("--marker", default="")
    p.add_argument("--end-marker", default="")
    p.add_argument("--strict", action="store_true")
    p.add_argument("--check-stale-events", action="store_true")
    p.add_argument("--fail-mouse-events", action="store_true")
    p.add_argument("--fail-key-events", action="store_true")
    p.add_argument("--forbid-focus-path", action="store_true")
    p.add_argument("--fail-front-restore", action="store_true")
    p.add_argument("--stale-window-ms", type=float, default=1800)
    p.add_argument("--par-hide-max-ms", type=float, default=2500)
    p.add_argument("--focus-target-max-ms", type=float, default=800)
    p.add_argument("--updates-total-max-ms", type=float, default=50)
    p.add_argument("--updates-windows-max-ms", type=float, default=45)
    p.add_argument("--show-prep-max-ms", type=float, default=80)
    p.add_argument("--guest-prefocus-max-ms", type=float, default=350)
    p.add_argument("--ax-title-fail-max", type=int, default=5)
    p.add_argument("--max-user-notification-windows", type=int, default=1)
    p.add_argument("--expected-final-wid", type=int, default=0)
    p.add_argument("--allow-restart-after-marker", action="store_true")
    return p.parse_args()

def read_lines(path: str, marker: str, end_marker: str) -> tuple[list[str], bool, bool]:
    text = Path(path).read_bytes().decode("utf-8", "replace")
    lines = text.splitlines()
    if not marker:
        return (lines, True, not end_marker)
    exact_marker = f"=== EVAL MARKER: {marker} ==="
    marker_indexes = [i for i, line in enumerate(lines) if exact_marker in line]
    if not marker_indexes:
        marker_indexes = [i for i, line in enumerate(lines) if marker in line and (not end_marker or end_marker not in line)]
    if not marker_indexes:
        print(f"WARN marker not found: {marker}", file=sys.stderr)
        return ([], False, False)
    start = marker_indexes[-1] + 1
    if not end_marker:
        return (lines[start:], True, True)
    end_indexes = [i for i, line in enumerate(lines[start:], start) if end_marker in line]
    if not end_indexes:
        return (lines[start:], True, False)
    return (lines[start:end_indexes[0]], True, True)

def t_ms(line: str) -> float | None:
    m = re.search(r"\bt\+([0-9.]+)ms", line)
    return float(m.group(1)) if m else None

def add(issues: list[Issue], severity: str, line: str, kind: str, msg: str):
    issues.append(Issue(severity, t_ms(line), kind, msg, line.strip()))

def scan(lines: list[str], args) -> list[Issue]:
    issues: list[Issue] = []
    focus_events: list[tuple[float, int, str]] = []
    ax_title_fails = 0
    saw_restart_after_marker = False
    saw_expected_focus_path = False
    for line in lines:
        when = t_ms(line)
        if "=== DEV BUILD:" in line or "=== DEV LOGGED RUN:" in line or "[DIAG INIT]" in line:
            saw_restart_after_marker = True
        key = re.search(r"release → focusSelectedWindow target=.*?\(wid:(\d+)\b", line)
        switch = re.search(r"\bfocusSelectedWindow \+[0-9.]+ms .*? wid=(\d+)\b", line)
        if when is not None and (key or switch):
            saw_expected_focus_path = True
            focus_events.append((when, int((key or switch).group(1)), line))
            if args.forbid_focus_path:
                add(issues, "FAIL", line, "unexpected-focus-path", "focusSelectedWindow appeared in a non-AltTab-focus eval")
        event = re.search(r"z-order review reason=(app-activated|focused-window) wid=(\d+)", line)
        if args.check_stale_events and when is not None and event and focus_events:
            wid = int(event.group(2))
            if wid != 0:
                latest = max((e for e in focus_events if e[0] <= when), default=None, key=lambda e: e[0])
                if latest is not None:
                    age = when - latest[0]
                    if 0 <= age <= args.stale_window_ms and wid != latest[1]:
                        add(issues, "FAIL", line, "stale-focus-event", f"{event.group(1)} wid={wid} arrived {age:.1f}ms after newer focus target wid={latest[1]}")
        par = re.search(r"parHideNow \+(?P<total>[0-9.]+)ms .*?\] (?P<elapsed>[0-9]+)ms ready=(?P<ready>\w+) stable=(?P<stable>[0-9]+)(?:/[0-9]+)?ms(?: stack=(?P<stack>[0-9]+)(?:/[0-9]+)?ms)? front=(?P<front>\w+) target=#(?P<target>\d+) top=#(?P<top>\d+)", line)
        if par:
            elapsed = float(par.group("elapsed"))
            ready = par.group("ready") == "true"
            front = par.group("front") == "true"
            target = int(par.group("target"))
            top = int(par.group("top"))
            if elapsed > args.par_hide_max_ms or not ready or not front or target != top:
                add(issues, "FAIL", line, "par-hide", f"parHideNow elapsed={elapsed:.1f}ms ready={ready} front={front} target={target} top={top}")
        guest = re.search(r"guestPrefocusDone .*?ok=(\w+).*?total=([0-9.]+)ms.*?sinceQueue=([0-9.]+)ms reason=(.*)$", line)
        if guest:
            ok = guest.group(1) == "true"
            total = float(guest.group(2))
            since_queue = float(guest.group(3))
            reason = guest.group(4)
            if ok and (total > args.guest_prefocus_max_ms or since_queue > args.guest_prefocus_max_ms):
                add(issues, "FAIL", line, "guest-prefocus-stale", f"successful guest prefocus completed after total={total:.1f}ms sinceQueue={since_queue:.1f}ms")
            if "stale-before-set queue=" in reason or since_queue > args.guest_prefocus_max_ms * 2:
                add(issues, "FAIL", line, "guest-prefocus-queue-delay", f"guest prefocus queue delay sinceQueue={since_queue:.1f}ms reason={reason[:120]}")
        ft = re.search(r"\bfocusTarget \+([0-9.]+)ms", line)
        if ft and float(ft.group(1)) > args.focus_target_max_ms:
            add(issues, "FAIL", line, "focus-target-latency", f"focusTarget took {float(ft.group(1)):.1f}ms")
        if re.search(r"\bfocusSelectedWindow \+[0-9.]+ms .*? wid=nil\b", line):
            add(issues, "FAIL", line, "nil-focus-target", "focusSelectedWindow ran without a selected window id")
        if "[DIAG ANOMALY]" in line:
            add(issues, "FAIL", line, "runtime-anomaly", "runtime focus/z/input invariant failed")
        upd = re.search(r"updatesBeforeShowing: total=([0-9.]+)ms .*?windows=([0-9.]+)ms", line)
        if upd:
            total = float(upd.group(1)); windows = float(upd.group(2))
            if total > args.updates_total_max_ms or windows > args.updates_windows_max_ms:
                add(issues, "FAIL", line, "panel-refresh-latency", f"updatesBeforeShowing total={total:.1f}ms windows={windows:.1f}ms")
        prep = re.search(r"show prep: .*?total=([0-9.]+)ms", line)
        if prep and float(prep.group(1)) > args.show_prep_max_ms:
            add(issues, "FAIL", line, "show-prep-latency", f"show prep total={float(prep.group(1)):.1f}ms")
        if "[DIAG SAMEAPP]" in line:
            add(issues, "WARN", line, "same-app-diagnostic", "broad same-app diagnostic fired; rely on sampler sibling-intrusion checks for pass/fail")
            unc = re.search(r"UserNotificationCenter=(\d+)", line)
            if unc and int(unc.group(1)) > args.max_user_notification_windows:
                add(issues, "FAIL", line, "popup-storm", f"UserNotificationCenter count={unc.group(1)} in top8")
        if "[DIAG CAPTURE]" in line and "watchdog hiding stuck input capture" in line:
            add(issues, "FAIL", line, "capture-watchdog", "input capture watchdog fired")
        if args.fail_mouse_events and "[DIAG MOUSE]" in line:
            add(issues, "FAIL", line, "mouse-contamination", "mouse event observed during bounded eval window")
        if args.fail_key_events and "[DIAG KEYEVENT]" in line:
            add(issues, "FAIL", line, "key-contamination", "key event observed during bounded eval window")
        if "stuck-popup detection:" in line:
            add(issues, "FAIL", line, "stuck-popup", "UserNotificationCenter stuck-popup flush fired")
        if "SCStreamErrorDomain" in line or "Code=-3802" in line:
            add(issues, "FAIL", line, "screencapturekit-error", "ScreenCaptureKit capture failed during eval")
        if "popup-storm-guard status=POPUP_STORM" in line or "EVAL ABORT POPUP STORM:" in line:
            add(issues, "FAIL", line, "popup-storm", "popup storm guard tripped")
        if "[DIAG FRONT_MISMATCH]" in line and "UserNotificationCenter" in line and ("— restoring" in line or "restore attempt:" in line):
            add(issues, "FAIL", line, "transient-frontmost-restore", "restored focus against transient UserNotificationCenter frontmost")
        if args.fail_front_restore and "[DIAG FRONT_MISMATCH]" in line and ("— restoring" in line or "restore attempt:" in line):
            add(issues, "FAIL", line, "front-restore", "frontmost mismatch restore fired during eval")
        if "native level pin" in line or "nativeMultiWindowRepoke" in line or "z0ActivationClick" in line:
            add(issues, "FAIL", line, "unsafe-experiment-path", "unsafe native focus experiment path appeared in logs")
        if " ERRO" in line or " ERROR" in line or "[DIAG ERROR]" in line:
            add(issues, "WARN", line, "error-log", "error-level log line observed")
        if "[DIAG AXTITLE]" in line and "AX failed" in line:
            ax_title_fails += 1
        if "cgsOrderDone" in line and "err=1000" in line:
            add(issues, "WARN", line, "cgs-order", "CGSOrderWindow returned err=1000")
    if ax_title_fails > args.ax_title_fail_max:
        issues.append(Issue("FAIL", None, "ax-title-failures", f"AX title failures count={ax_title_fails} > {args.ax_title_fail_max}", ""))
    if saw_restart_after_marker and not args.allow_restart_after_marker:
        issues.append(Issue("FAIL", None, "restart-after-marker", "AltTab restarted after the eval marker; this run is contaminated and log assertions are not trustworthy", ""))
    if args.expected_final_wid and not saw_expected_focus_path:
        issues.append(Issue("FAIL", None, "missing-focus-path", f"no focusSelectedWindow log lines after marker; expected final wid={args.expected_final_wid}", ""))
    if args.expected_final_wid and focus_events and focus_events[-1][1] != args.expected_final_wid:
        issues.append(Issue("FAIL", focus_events[-1][0], "final-focus-target", f"last focus target wid={focus_events[-1][1]}, expected {args.expected_final_wid}", focus_events[-1][2].strip()))
    return issues

def main():
    args = parse_args()
    lines, marker_found, end_found = read_lines(args.log, args.marker, args.end_marker)
    issues = scan(lines, args)
    if args.marker and not marker_found:
        issues.append(Issue("FAIL", None, "log-marker-missing", f"marker not found in {args.log}: {args.marker}", ""))
    if args.marker and marker_found and not lines:
        issues.append(Issue("FAIL", None, "log-marker-empty", f"no log lines after marker in {args.log}; AltTab may not be logging to the scanned file", ""))
    if args.end_marker and not end_found:
        issues.append(Issue("FAIL", None, "log-end-marker-missing", f"end marker not found in {args.log}: {args.end_marker}", ""))
    fail_count = sum(1 for i in issues if i.severity == "FAIL")
    warn_count = sum(1 for i in issues if i.severity == "WARN")
    print(f"log-anomalies marker={args.marker or '<none>'} lines={len(lines)} failures={fail_count} warnings={warn_count}")
    for issue in issues:
        where = f" t+{issue.t_ms:.3f}ms" if issue.t_ms is not None else ""
        print(f"{issue.severity} {issue.kind}{where}: {issue.message}")
        if issue.line:
            print(f"  {issue.line[:500]}")
    if args.strict and fail_count:
        sys.exit(1)

if __name__ == "__main__":
    main()
