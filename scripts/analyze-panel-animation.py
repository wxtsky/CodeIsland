#!/usr/bin/env python3
"""Summarize the opt-in real-panel benchmark; never treat static time as low FPS.

Usage: python3 scripts/analyze-panel-animation.py build-dir/bench-original
ScreenCaptureKit observations are captured updates, not physical display FPS.
"""
import argparse
import csv
import json
import statistics
from pathlib import Path


def read(path):
    with path.open() as stream:
        return list(csv.DictReader(stream))


def analyze(directory):
    frames = [(float(r['time']), int(r['edge'])) for r in read(directory / 'frames.csv') if int(r['status']) == 0]
    events = [(float(r['host_time']), r['event'].split('-')[0]) for r in read(directory / 'events.csv')]
    layouts = [(float(r['host_time']), float(r['duration_ms'])) for r in read(directory / 'layouts.csv')]
    ticks = [float(r['host_time']) for r in read(directory / 'ticks.csv')]
    results = {'open': [], 'close': []}
    for index, (start, kind) in enumerate(events):
        stop = min(start + .8, events[index + 1][0] if index + 1 < len(events) else start + .8)
        before = [f for f in frames if f[0] <= start]
        observed = ([before[-1]] if before else []) + [f for f in frames if start < f[0] < stop]
        if len(observed) < 3:
            continue
        low, high = min(y for _, y in observed), max(y for _, y in observed)
        if high - low < 50:
            continue
        lower, upper = low + .05 * (high-low), low + .95 * (high-low)
        if kind == 'open':
            first = next((i for i, (_, y) in enumerate(observed) if y > lower), None)
            last = next((i for i, (_, y) in enumerate(observed) if y >= upper), None)
        else:
            first = next((i for i, (_, y) in enumerate(observed) if y < upper), None)
            last = next((i for i, (_, y) in enumerate(observed) if y <= lower), None)
        if first is None or last is None or first == 0 or first > last:
            continue
        segment = observed[max(0, first-1):last+1]
        changes = [segment[0]] + [b for a,b in zip(segment, segment[1:]) if a[1] != b[1]]
        intervals = [(b[0]-a[0])*1000 for a,b in zip(changes, changes[1:])]
        if not intervals:
            continue
        run_layouts = [ms for t,ms in layouts if start <= t < stop]
        run_ticks = [(b-a)*1000 for a,b in zip(ticks,ticks[1:]) if b >= start and a < stop]
        results[kind].append({
            'event_index': index,
            'captured_updates_per_second': len(intervals)*1000/sum(intervals),
            'longest_update_gap_ms': max(intervals),
            'first_visible_change_ms': (observed[first][0]-start)*1000,
            'layout_total_ms': sum(run_layouts),
            'layout_max_ms': max(run_layouts, default=0),
            'main_timer_max_gap_ms': max(run_ticks, default=0),
        })
    output = {'directory': str(directory), 'runs': results, 'summary': {}}
    for kind, runs in results.items():
        if runs:
            output['summary'][kind] = {
                'count': len(runs),
                'median_captured_updates_per_second': statistics.median(r['captured_updates_per_second'] for r in runs),
                'median_first_visible_change_ms': statistics.median(r['first_visible_change_ms'] for r in runs),
                'longest_update_gap_ms': max(r['longest_update_gap_ms'] for r in runs),
                'max_layout_ms': max(r['layout_max_ms'] for r in runs),
                'max_main_timer_gap_ms': max(r['main_timer_max_gap_ms'] for r in runs),
            }
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directories', nargs='+', type=Path)
    args = parser.parse_args()
    for directory in args.directories:
        result = analyze(directory)
        (directory / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
        print(directory)
        print(json.dumps(result['summary'], indent=2))
