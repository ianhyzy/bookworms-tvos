#!/usr/bin/env python3
"""Export selected Instruments tables and summarize measured intervals, not XCTest latency."""
import argparse
import bisect
from collections import Counter, defaultdict
import json
import math
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


def rows(path):
    root = ET.parse(path).getroot()
    identifiers = {e.get('id'): e for e in root.iter() if e.get('id')}
    def resolved(e):
        return identifiers[e.get('ref')] if e.get('ref') else e
    schema = root.find('.//schema')
    names = [c.findtext('mnemonic') for c in schema.findall('col')] if schema is not None else []
    return [{name: resolved(e) for name, e in zip(names, row)} for row in root.findall('.//row')], resolved


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
    result = {'trace': str(args.trace), 'duration_seconds': root.findtext('.//duration'), 'tables': {}}
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
    result['available_schemas'] = sorted(schemas)
    (args.output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ['cpu','available_schemas']},indent=2))


if __name__ == '__main__':
    main()
