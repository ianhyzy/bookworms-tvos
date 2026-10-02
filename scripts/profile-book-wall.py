#!/usr/bin/env python3
"""Build, record, and summarize one Book Wall performance profile on the physical Apple TV.

Runs unattended: wakes the Instruments connection, builds an optimized test build, drives
the Siri Remote through `DevicePerformanceTests/testBookWallProfile`, symbolicates the trace,
summarizes it, and reinstalls the ordinary local build.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / '.local/performance-diagnosis'


def prune(folder):
    """Deletes a run's traces and exported tables (about 240 MB); summaries, logs, and the
    test's screenshots stay."""
    if (folder / 'test.xcresult').exists() and not (folder / 'attachments').exists():
        subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path',
                        str(folder / 'test.xcresult'), '--output-path', str(folder / 'attachments')],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for pattern in ['*.trace', 'test.xcresult', 'tables/*.xml']:
        for path in folder.glob(pattern):
            shutil.rmtree(path) if path.is_dir() else path.unlink()


def instruments_scratch():
    """Kernel-trace buffers, 1-2 GB each, that xctrace leaves in the temporary folder."""
    return set(Path(tempfile.gettempdir()).glob('instruments*.ktrace'))


def run(args, **kwargs):
    print('+', ' '.join(str(a) for a in args), flush=True)
    return subprocess.run(args, check=True, cwd=ROOT, **kwargs)


def device_build_module():
    spec = importlib.util.spec_from_file_location('device_build', ROOT / 'scripts/device-build.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ensure_trace_device(device, name):
    """Instruments can list a paired TV as offline until a CoreDevice session wakes it."""
    for attempt in range(4):
        subprocess.run(['xcrun', 'devicectl', 'device', 'info', 'details', '--device', device],
                       cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        listing = subprocess.run(['xcrun', 'xctrace', 'list', 'devices'], cwd=ROOT,
                                 capture_output=True, text=True).stdout
        online = listing.split('== Devices Offline ==')[0]
        if re.search(rf'^{re.escape(name)} \(', online, re.MULTILINE):
            return
        time.sleep(5)
    raise SystemExit(f'Instruments lists "{name}" as offline. Wake the TV and retry.')


def reboot(device):
    """Restarts the TV, which frees the storage each recording leaves behind.

    After about 6 to 25 recordings without a restart, the recorder failed and installs reported
    insufficient storage. A restart also gives every run the same starting state.
    """
    for attempt in range(2):
        # The restart request needs a live CoreDevice connection, which an idle TV drops.
        subprocess.run(['xcrun', 'devicectl', 'device', 'info', 'details', '--device', device],
                       cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            run(['xcrun', 'devicectl', 'device', 'reboot', '--device', device,
                 '--wait-for-device', '--timeout', '300'], stdout=subprocess.DEVNULL)
            break
        except subprocess.CalledProcessError:
            if attempt:
                raise
            time.sleep(30)
    # Let post-boot background work settle before measuring.
    time.sleep(90)


def phases(log_path):
    """Returns the test's phase markers with their wall-clock times."""
    found = []
    for line in log_path.read_text(errors='replace').splitlines():
        match = re.search(r'PERFORMANCE_PHASE (\S+) ([0-9.]+)', line)
        if match:
            found.append({'phase': match.group(1), 'epoch': float(match.group(2))})
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true', help='Reuse the last .build-profile')
    parser.add_argument('--keep-test-build', action='store_true',
                        help='Leave the profiled build installed instead of the local build')
    parser.add_argument('--diagnostics', action='store_true',
                        help='Build with BOOKWORMS_DIAGNOSTICS into .build-profile-diagnostics and '
                             'launch with --performance-diagnostics')
    parser.add_argument('--variant', help='Isolation such as wall-no-shadow; implies --diagnostics')
    parser.add_argument('--wall-antialiasing', choices=['off', 'on'], default='on',
                        help='Book Wall antialiasing (default: on)')
    parser.add_argument('--capture-set', choices=['full', 'display', 'cpu'], default='display',
                        help='Instruments: Display + Points of Interest (default), full (adds Time '
                             'Profiler, Hitches, and GPU), or Time Profiler + Points of Interest. '
                             'Lighter sets lose less data over the network; compare matching sets')
    parser.add_argument('--sequence', choices=['full', 'details'], default='full',
                        help='Every phase (default), or only opening and closing details')
    parser.add_argument('--label', default='book-wall', help='Suffix for the output folder')
    parser.add_argument('--no-reboot', action='store_true',
                        help='Skip restarting the TV before recording')
    parser.add_argument('--reboot-every', type=int, default=4, metavar='N',
                        help='Restart the TV before every Nth recording (default 4; 1 restarts '
                             'before each one). Storage ran out after 6 to 25 recordings.')
    parser.add_argument('--keep-trace', action='store_true',
                        help='Keep the trace and exported tables for drill-down; prune them later')
    parser.add_argument('--prune', action='store_true',
                        help='Delete traces and tables from every run, plus leftover xctrace '
                             'buffers, then exit')
    args = parser.parse_args()
    if args.prune:
        if subprocess.run(['pgrep', '-x', 'xctrace'], stdout=subprocess.DEVNULL).returncode == 0:
            raise SystemExit('xctrace is running; prune after it finishes.')
        for folder in RESULTS.glob('*/'):
            prune(folder)
        for path in instruments_scratch():
            path.unlink()
        return 0
    args.diagnostics = args.diagnostics or bool(args.variant)
    derived = ROOT / ('.build-profile-diagnostics' if args.diagnostics else '.build-profile')
    products = derived / 'Build/Products'
    defaults = json.loads((ROOT / '.local/device-build.json').read_text())
    device, team = defaults['device'], defaults['team']
    trace_device = defaults.get('traceDevice', 'Living Room')

    if not args.skip_build:
        run(['xcodebuild', '-project', 'Bookworms.xcodeproj', '-scheme', 'BookwormsDevice',
             '-configuration', 'Release', '-testPlan', 'Device', '-destination', f'id={device}',
             '-derivedDataPath', str(derived), f'DEVELOPMENT_TEAM={team}',
             *(['SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BOOKWORMS_DIAGNOSTICS']
               if args.diagnostics else []),
             'CLANG_ENABLE_CODE_COVERAGE=NO', '-enableCodeCoverage', 'NO',
             'ENABLE_TESTABILITY=YES', 'DEBUG_INFORMATION_FORMAT=dwarf-with-dsym',
             'build-for-testing', '-quiet'])
    # Counts recordings since the last restart across separate invocations.
    counter = RESULTS / '.recordings-since-reboot'
    since = int(counter.read_text()) if counter.exists() else args.reboot_every
    if not args.no_reboot and since >= args.reboot_every:
        reboot(device)
        since = 0
    RESULTS.mkdir(parents=True, exist_ok=True)
    counter.write_text(f'{since + 1}\n')
    ensure_trace_device(device, trace_device)
    xctestrun = max(products.glob('BookwormsDevice_*.xctestrun'), key=lambda p: p.stat().st_mtime)
    output = RESULTS / f"{time.strftime('%Y%m%d-%H%M%S')}-{args.label}"
    output.parent.mkdir(parents=True, exist_ok=True)

    result = 0
    try:
        run([sys.executable, 'scripts/profile-device.py', '--device', device,
             '--trace-device', trace_device, '--xctestrun', str(xctestrun),
             '--scenario', 'bookWall', '--output', str(output),
             '--wall-antialiasing', args.wall_antialiasing,
             '--capture-set', args.capture_set, '--sequence', args.sequence,
             *(['--diagnostics'] if args.diagnostics else []),
             *(['--variant', args.variant] if args.variant else [])])
    except subprocess.CalledProcessError as error:
        result = error.returncode
    finally:
        device_build_module().clean_test_runner(device)

    if args.diagnostics:
        # The app keeps its renderer windows on the TV; streamed Instruments data can have gaps.
        copied = subprocess.run(
            ['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device,
             '--domain-type', 'appDataContainer', '--domain-identifier', 'gay.ian.Bookworms',
             '--source', 'Library/Caches/BookWallPipeline.jsonl',
             '--destination', str(output / 'pipeline.jsonl')],
            cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if copied.returncode:
            print('Could not copy the renderer pipeline log from the TV.', file=sys.stderr)
    log = output / 'test.log'
    if log.exists():
        (output / 'phases.json').write_text(json.dumps(phases(log), indent=2) + '\n')
    trace = output / 'recording.trace'
    manifest_path = output / 'manifest.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    # xctrace can exit with an error after saving a usable trace, for example when one data
    # provider reports errors, so summarize any trace from a passing test.
    if manifest.get('test_exit') == 0 and trace.exists():
        dsym = products / 'Release-appletvos/Bookworms.app.dSYM'
        symbolicated = output / 'recording-symbolicated.trace'
        # Only CPU samples need symbols.
        if args.capture_set != 'display':
            try:
                run(['xcrun', 'xctrace', 'symbolicate', '--input', str(trace), '--dsym',
                     str(dsym), '--output', str(symbolicated)])
                trace = symbolicated
            except subprocess.CalledProcessError:
                print('Symbolication failed; summarizing the raw trace.', file=sys.stderr)
        # The summarizer writes the complete report to tables/summary.json.
        try:
            run([sys.executable, 'scripts/summarize-performance-trace.py', str(trace),
                 '--output', str(output / 'tables')], stdout=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            print('The trace could not be read; this run has no summary.', file=sys.stderr)
    if args.keep_trace:
        print('Kept the trace; run with --prune when the analysis is done.')
    else:
        prune(output)
    if not args.keep_test_build:
        run([sys.executable, 'scripts/device-build.py', '--start-view', 'bookWall'])
    print(f'Profile folder: {output}')
    return result


if __name__ == '__main__':
    sys.exit(main())
