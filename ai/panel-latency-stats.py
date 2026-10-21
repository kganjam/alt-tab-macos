#!/usr/bin/env python3
"""Switcher show latency from AltTab logs: median/p90 per metric.

  python3 ai/panel-latency-stats.py [--since-utc-ms N] [log ...]   (default /tmp/alttab/latest.log)

- on screen: `panel on screen` (WindowServer reports the panel visible): the user-visible latency.
  `sinceShowStart` is from the keypress; it lags the real first frame by ~25 ms (notification delivery).
- render complete: `panel render complete`, a CATransaction completion that comes ~0.45 s after the
  panel is fully drawn (experiments/notebook.md, 2026-10-21). Kept for comparison with older logs.
- build: `display delay: ... (normal)` to `showPanel` minus the delay: the tile build (refreshUi).
"""
import argparse
import re
import statistics

UTC = re.compile(r'utcMs=(\d+)')
METRICS = {
    'on screen sinceShowStart': (re.compile(r'panel on screen: sinceShowStart=(-?\d+)ms'), 1),
    'on screen sinceOrderFront': (re.compile(r'panel on screen: .*sinceOrderFront=(-?\d+)ms'), 1),
    'render complete sinceShowStart': (re.compile(r'panel render complete: sinceShowStart=(-?\d+)ms'), 1),
    'render complete build+render': (re.compile(r'panel render complete: .*build\+render=(-?\d+)ms'), 1),
}
DELAY = re.compile(r'display delay: milliseconds\((\d+)\) \(normal\)')


def p90(values):
    ordered = sorted(values)
    return ordered[round(0.9 * (len(ordered) - 1))]


def collect(paths, since):
    found = {name: [] for name in list(METRICS) + ['build']}
    for path in paths:
        delay_at = None
        with open(path, errors='replace') as log:
            for line in log:
                stamp = UTC.search(line)
                if not stamp or int(stamp.group(1)) < since:
                    continue
                at = int(stamp.group(1))
                delay = DELAY.search(line)
                if delay:
                    delay_at = (at, int(delay.group(1)))
                elif 'showPanel (window count' in line and delay_at:
                    found['build'].append(at - delay_at[0] - delay_at[1])
                    delay_at = None
                for name, (pattern, group) in METRICS.items():
                    match = pattern.search(line)
                    if match and int(match.group(group)) >= 0:
                        found[name].append(int(match.group(group)))
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--since-utc-ms', type=int, default=0)
    parser.add_argument('logs', nargs='*', default=['/tmp/alttab/latest.log'])
    args = parser.parse_args()
    for name, values in collect(args.logs, args.since_utc_ms).items():
        if values:
            print(f'{name:32s} n={len(values):4d} median={statistics.median(values):6.0f}ms p90={p90(values):6d}ms')


if __name__ == '__main__':
    main()
