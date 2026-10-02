#!/usr/bin/env python3
"""Export selected Instruments tables and summarize measured intervals, not XCTest latency."""
import argparse
import bisect
from collections import Counter, defaultdict
from datetime import datetime
import json
import math
import re
import statistics
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET


def distribution(values):
    ordered = sorted(values)
    if not ordered:
        return {'count': 0}
    return {'count': len(ordered), 'total_ms': sum(ordered),
            'median_ms': statistics.median(ordered),
            'p95_ms': ordered[max(0, math.ceil(len(ordered)*.95)-1)], 'worst_ms': ordered[-1]}


def observation_status(schema, count, schemas):
    """Distinguishes an unavailable provider from a phase with no observed samples."""
    if schema not in schemas:
        return {'status': 'schema_absent', 'count': None}
    return {'status': 'samples_present' if count else 'no_samples', 'count': count}


def rows(path):
    root = ET.parse(path).getroot()
    identifiers = {e.get('id'): e for e in root.iter() if e.get('id')}
    def resolved(e):
        return identifiers[e.get('ref')] if e.get('ref') else e
    schema = root.find('.//schema')
    names = [c.findtext('mnemonic') for c in schema.findall('col')] if schema is not None else []
    return [{name: resolved(e) for name, e in zip(names, row)} for row in root.findall('.//row')], resolved


def export(args, schema):
    path = args.output/(schema+'.xml')
    if not path.exists():
        subprocess.run(['xcrun','xctrace','export','--input',str(args.trace),'--xpath',
                        f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]',
                        '--output',str(path)], check=True, stdout=subprocess.DEVNULL)
    return rows(path)


def phase_report(args, root, schemas, markers):
    """Splits frame pacing, hitches, GPU time, and main-thread CPU by the test's phase markers.

    Markers carry wall-clock epochs; the trace's start date converts them to trace time.
    """
    start = datetime.fromisoformat(root.findtext('.//start-date')).timestamp()
    bounds = [(m['phase'], (m['epoch']-start)*1000) for m in markers]
    windows = [(name, begin, bounds[i+1][1] if i+1 < len(bounds) else math.inf)
               for i, (name, begin) in enumerate(bounds)]
    ms = lambda e: int(e.text)/1e6
    swaps = []
    if 'display-surface-swap' in schemas:
        data, _ = export(args, 'display-surface-swap')
        names = Counter(r['display-name'].text for r in data if 'display-name' in r)
        main_display = names.most_common(1)[0][0] if names else None
        swaps = sorted(ms(r['timestamp']) for r in data
                       if 'display-name' in r and r['display-name'].text == main_display)
    gpu = []; compositor = []
    if 'metal-gpu-intervals' in schemas:
        data, _ = export(args, 'metal-gpu-intervals')
        for r in data:
            process = r['process'].get('fmt') or '' if 'process' in r else ''
            interval = (ms(r['start']), ms(r['duration']))
            if 'Bookworms' in process:
                gpu.append(interval)
            elif 'backboardd' in process:
                compositor.append(interval)
    hitches = []
    if 'hitches' in schemas:
        data, _ = export(args, 'hitches')
        hitches = [(ms(r['start']), ms(r['duration'])) for r in data]
    samples = []
    if 'time-profile' in schemas:
        data, resolve = export(args, 'time-profile')
        for r in data:
            if 'Main Thread' not in (r['thread'].get('fmt') or ''):
                continue
            frames = [resolve(f).get('name') for f in r['stack'].findall('frame')]
            samples.append((ms(r['time']), ms(r['weight']), frames))
    # The renderer host's one-second pipeline windows, from Points of Interest. They count
    # frames the app submitted and display ticks it skipped, not frames shown, and survive
    # gaps in Instruments' Display and GPU data. The export repeats each event.
    pipeline = []
    # Prefer the app's own log, copied from the TV after the run; it has no streaming gaps.
    log = args.trace.parent/'pipeline.jsonl'
    if log.exists():
        for line in log.read_text().splitlines():
            entry = json.loads(line)
            pipeline.append(((entry['epoch']-start)*1000, int(entry['submitted']),
                             int(entry['skipped']), entry.get('maxTickGapMS')))
    elif 'os-signpost' in schemas:
        data, _ = export(args, 'os-signpost')
        seen = set()
        for r in data:
            name = r.get('name')
            if name is None or (name.text or name.get('fmt')) != 'BookWallRendererPipeline':
                continue
            message = r['message'].get('fmt') or r['message'].text or ''
            fields = dict(re.findall(r'(\w+)=(\S+)', message))
            if fields.get('reason') != 'window' or (r['time'].text, message) in seen:
                continue
            seen.add((r['time'].text, message))
            pipeline.append((ms(r['time']), int(fields['submitted']), int(fields['skipped']), None))
    report = []
    for name, begin, end in windows:
        inside = lambda t: begin <= t < end
        stamps = [t for t in swaps if inside(t)]
        intervals = [b-a for a, b in zip(stamps, stamps[1:])]
        cpu = [(w, f) for t, w, f in samples if inside(t)]
        own = Counter(); app = Counter()
        for weight, frames in cpu:
            if frames:
                own[frames[0]] += weight
            for frame in set(frames):
                if frame and any(k in frame for k in ['BookWall', 'ShelfView', 'BookDetail']):
                    app[frame] += weight
        report.append({
            'phase': name, 'start_ms': round(begin, 1),
            'duration_ms': None if end == math.inf else round(end-begin, 1),
            'observations': {
                'display_swaps': {
                    **observation_status('display-surface-swap', len(stamps), schemas),
                    'first_offset_ms': round(stamps[0]-begin, 3) if stamps else None,
                    'last_offset_ms': round(stamps[-1]-begin, 3) if stamps else None,
                },
                'app_gpu_intervals': observation_status(
                    'metal-gpu-intervals', sum(inside(t) for t, _ in gpu), schemas),
                'compositor_gpu_intervals': observation_status(
                    'metal-gpu-intervals', sum(inside(t) for t, _ in compositor), schemas),
                'main_thread_cpu_samples': observation_status('time-profile', len(cpu), schemas),
                'hitches': observation_status('hitches', sum(inside(t) for t, _ in hitches), schemas),
            },
            'frame_intervals': distribution(intervals) if 'display-surface-swap' in schemas else None,
            # Frames shown in each whole second of the phase, to locate slow stretches.
            'frames_per_second': [sum(begin+i*1000 <= t < begin+(i+1)*1000 for t in stamps)
                                  for i in range(int(((min(end, stamps[-1]) if stamps else begin)
                                                      - begin)//1000))]
                                  if 'display-surface-swap' in schemas else None,
            'frames_over_20ms': sum(i > 20 for i in intervals) if 'display-surface-swap' in schemas else None,
            'frames_over_34ms': sum(i > 34 for i in intervals) if 'display-surface-swap' in schemas else None,
            'hitches': distribution([d for t, d in hitches if inside(t)]) if 'hitches' in schemas else None,
            'gpu_busy_ms': round(sum(d for t, d in gpu if inside(t)), 1)
                           if 'metal-gpu-intervals' in schemas else None,
            'compositor_gpu_ms': round(sum(d for t, d in compositor if inside(t)), 1)
                                 if 'metal-gpu-intervals' in schemas else None,
            # Submitted frames and skipped ticks per renderer window that ended in this phase.
            'renderer_submitted_per_second': [n for t, n, _, _ in pipeline if inside(t)] or None,
            'renderer_skipped_per_second': [k for t, _, k, _ in pipeline if inside(t)] or None,
            # The longest gap between display-link callbacks, which a main-thread stall widens.
            'renderer_max_tick_gap_ms': max((g for t, _, _, g in pipeline
                                             if inside(t) and g is not None), default=None),
            # App and compositor GPU time in each whole second, aligned with frames_per_second.
            'gpu_ms_per_second': [[round(sum(d for t, d in source
                                             if begin+i*1000 <= t < begin+(i+1)*1000), 1)
                                   for i in range(int(((end if end != math.inf else begin) - begin)//1000))]
                                  for source in (gpu, compositor)]
                                 if 'metal-gpu-intervals' in schemas else None,
            'main_thread_ms': round(sum(w for w, _ in cpu), 1) if 'time-profile' in schemas else None,
            'main_self_top': own.most_common(8) if 'time-profile' in schemas else None,
            'app_inclusive_top': app.most_common(10) if 'time-profile' in schemas else None,
        })
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    toc = args.output/'toc.xml'
    if not toc.exists():
        subprocess.run(['xcrun','xctrace','export','--input',str(args.trace),'--toc','--output',str(toc)],check=True)
    root = ET.parse(toc).getroot()
    schemas = {t.get('schema') for t in root.findall('.//table')}
    selected = ['hitches','potential-hangs','swiftui-updates','os-signpost','os-signpost-interval','time-profile']
    result = {'trace': str(args.trace), 'duration_seconds': root.findtext('.//duration'), 'tables': {},
              'cpu': None,
              'measurement_availability': {
                  'display_swaps': 'display-surface-swap' in schemas,
                  'gpu_intervals': 'metal-gpu-intervals' in schemas,
                  'cpu_samples': 'time-profile' in schemas,
                  'hitches': 'hitches' in schemas,
              },
              'observation_note': 'Sample presence does not establish whole-phase coverage.'}
    for schema in selected:
        if schema not in schemas:
            continue
        output = args.output/(schema+'.xml')
        if not output.exists():
            subprocess.run(['xcrun','xctrace','export','--input',str(args.trace),'--xpath',
                            f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]',
                            '--output',str(output)], check=True,stdout=subprocess.DEVNULL)
        data, resolve = rows(output)
        result['tables'][schema] = {'rows':len(data)}
        if schema in ['hitches','potential-hangs']:
            values = [int(r['duration'].text)/1e6 for r in data if 'duration' in r]
            result['tables'][schema].update(distribution(values))
            if schema == 'hitches':
                result['tables'][schema]['attribution'] = dict(Counter(
                    r.get('narrative-description', ET.Element('unknown')).text for r in data))
        if schema == 'os-signpost':
            markers = [r for r in data if r.get('subsystem') is not None
                       and r['subsystem'].text == 'gay.ian.Bookworms.performance']
            # Multiple signpost tables can expose the same event. Count it once.
            unique = {}
            for r in markers:
                key = tuple(r[k].text for k in ['time', 'thread', 'event-type', 'identifier', 'name'])
                unique[key] = r
            markers = sorted(unique.values(), key=lambda r: int(r['time'].text))
            starts = {}; intervals = defaultdict(list); counts = Counter()
            pending_press = None; focus_delays = []; unmatched = 0; failures = 0; presses = []
            focus_pairs = []
            for r in markers:
                name = r['name'].text
                event = r['event-type'].get('fmt', r['event-type'].text or '')
                stamp = int(r['time'].text)/1e6
                key = (name, r['identifier'].text)
                counts[name] += 1
                if 'Begin' in event:
                    starts[key] = stamp
                elif 'End' in event and key in starts:
                    intervals[name].append(stamp - starts.pop(key))
                if name == 'DeliveredPress':
                    presses.append(stamp)
                    if pending_press is not None: unmatched += 1
                    pending_press = stamp
                elif name == 'NativeFocusChanged' and pending_press is not None:
                    focus_delays.append(stamp - pending_press)
                    focus_pairs.append({'press_ms': pending_press, 'notification_ms': stamp,
                                        'delay_ms': stamp-pending_press})
                    pending_press = None
                elif name == 'NativeFocusFailed':
                    failures += 1
            result['markers'] = {'press_times_ms':presses, 'counts':dict(counts),
                                 'intervals':{k:distribution(v) for k,v in intervals.items()},
                                 'delivered_press_to_first_focus_notification':distribution(focus_delays),
                                 'unpaired_presses':unmatched + int(pending_press is not None),
                                 'focus_failure_notifications':failures,
                                 'focus_pairs': focus_pairs,
                                 'note':'Includes notification delivery only, not display latency. Boundary failures are not automatically lost input.'}
        if schema == 'time-profile':
            inclusive = Counter(); own = Counter(); threads = Counter()
            for r in data:
                weight = int(r['weight'].text)/1e6
                threads[r['thread'].get('fmt')] += weight
                frames = [resolve(f).get('name') for f in r['stack'].findall('frame')]
                if frames:
                    own[frames[0]] += weight
                for name in set(frames):
                    inclusive[name] += weight
            result['cpu'] = {'sampled_ms':sum(threads.values()),'threads':dict(threads),
                             'self_top':own.most_common(25),'inclusive_top':inclusive.most_common(35),
                             'app_paths':[(n,v) for n,v in inclusive.most_common() if any(
                                 x in n for x in ['ShelfView','AmbientView','BookPresentation','SharedRead',
                                                'ComparisonOrder','CredentialStore','SettingsView','ReviewText'])]}
    manifest_path = args.trace.parent/'manifest.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    scenario = manifest.get('scenario', 'sidebar')
    result['scenario'] = scenario
    result['capture_set'] = manifest.get('capture_set', 'full')
    presses = result.get('markers', {}).get('press_times_ms', [])
    if (args.output/'hitches.xml').exists():
        hitch_rows, _ = rows(args.output/'hitches.xml')
        phases = defaultdict(dict)
        for schema in ['hitches-updates', 'hitches-renders', 'hitches-gpu']:
            path = args.output/(schema+'.xml')
            if not path.exists():
                continue
            phase_rows, _ = rows(path)
            for phase in phase_rows:
                if int(phase['containment-level'].text) != 0:
                    continue
                key = (phase['display'].text, phase['swap-id'].text)
                phases[key][schema] = {
                    'start_ms': int(phase['start'].text)/1e6,
                    'duration_ms': int(phase['duration'].text)/1e6,
                }
        result['worst_hitches'] = []
        for row in sorted(hitch_rows, key=lambda r: int(r['duration'].text), reverse=True)[:20]:
            start = int(row['start'].text)/1e6
            preceding = bisect.bisect_right(presses, start)-1
            result['worst_hitches'].append({
                'start_ms': start, 'duration_ms': int(row['duration'].text)/1e6,
                'preceding_press_ms': presses[preceding] if preceding >= 0 else None,
                'swap_id': row['swap-id'].text,
                'phases': phases.get((row['display'].text, row['swap-id'].text), {}),
                'attribution': row.get('narrative-description', ET.Element('unknown')).text,
            })
    if presses and scenario != 'longevity' and (args.output/'hitches.xml').exists():
        hitch_rows, _ = rows(args.output/'hitches.xml')
        result['measured_runs'] = []
        for index in range(0, len(presses), 40):
            group = presses[index:index+40]
            if len(group) != 40:
                continue
            begin, end = group[0], group[-1]+600
            selected_hitches = [r for r in hitch_rows if begin <= int(r['start'].text)/1e6 <= end]
            result['measured_runs'].append({
                'press_count':len(group), 'start_ms':begin,'end_ms':end,
                'hitches':distribution([int(r['duration'].text)/1e6 for r in selected_hitches])})
    phase_file = args.trace.parent/'phases.json'
    if phase_file.exists():
        result['phases'] = phase_report(args, root, schemas, json.loads(phase_file.read_text()))
    result['available_schemas'] = sorted(schemas)
    (args.output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ['cpu','available_schemas']},indent=2))


if __name__ == '__main__':
    main()
