#!/usr/bin/env python3
"""Switcher show latency from AltTab logs: median/p90 per metric.

  python3 ai/panel-latency-stats.py [--since-utc-ms N] [log ...]   (default /tmp/alttab/latest.log)

- on screen: `panel on screen` (WindowServer reports the panel visible): the user-visible latency.
  `sinceShowStart` is from the keypress; it lags the real first frame by ~25 ms (notification delivery).
- render complete: `panel render complete`, a CATransaction completion that comes ~0.45 s after the
  panel is fully drawn (experiments/notebook.md, 2026-10-21). Kept for comparison with older logs.
- build: `display delay` to `showPanel` minus the delay: the tile build (refreshUi).
Each show is grouped by its display delay (`windowDisplayDelay`, or the longer Parallels Coherence ones),
which `sinceShowStart` includes.
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
DELAY = re.compile(r'display delay: (?:milliseconds\((\d+)\) \(normal\)|(\d+)ms \((coherence) src=(\w+) tgt=(\w+) same=(\w+)\))')


def p90(values):
    ordered = sorted(values)
    return ordered[round(0.9 * (len(ordered) - 1))]


def delay_group(match):
    if match.group(1):
        return int(match.group(1)), f'normal {match.group(1)}ms'
    kind = 'same-boundary' if match.group(6) == 'true' else ('from Parallels' if match.group(4) == 'true' else 'to Parallels')
    return int(match.group(2)), f'coherence {match.group(2)}ms {kind}'


def collect(paths, since):
    found = {}
    for path in paths:
        delay = None
        with open(path, errors='replace') as log:
            for line in log:
                stamp = UTC.search(line)
                if not stamp or int(stamp.group(1)) < since:
                    continue
                at = int(stamp.group(1))
                match = DELAY.search(line)
                if match:
                    delay = (at,) + delay_group(match)
                    continue
                if delay is None:
                    continue
                group = found.setdefault(delay[2], {name: [] for name in ['build'] + list(METRICS)})
                if 'showPanel (window count' in line and delay[0] > 0:
                    group['build'].append(at - delay[0] - delay[1])
                    delay = (0,) + delay[1:]
                for name, (pattern, index) in METRICS.items():
                    metric = pattern.search(line)
                    if metric and int(metric.group(index)) >= 0:
                        group[name].append(int(metric.group(index)))
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--since-utc-ms', type=int, default=0)
    parser.add_argument('logs', nargs='*', default=['/tmp/alttab/latest.log'])
    args = parser.parse_args()
    for group, metrics in sorted(collect(args.logs, args.since_utc_ms).items()):
        print(group)
        for name, values in metrics.items():
            if values:
                print(f'  {name:32s} n={len(values):4d} median={statistics.median(values):6.0f}ms p90={p90(values):6d}ms')


if __name__ == '__main__':
    main()
