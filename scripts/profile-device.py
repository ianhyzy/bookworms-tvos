#!/usr/bin/env python3
"""Record one opt-in menu scenario without mixing screenshots into the timed interval."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--trace-device', default='Living Room', help='Instruments device name; its UDID lookup can differ from devicectl')
    parser.add_argument('--xctestrun', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--app', type=Path, help='Override with an ordinary Release baseline app')
    parser.add_argument('--diagnostics', action='store_true')
    parser.add_argument('--variant', choices=['glass', 'background'])
    parser.add_argument('--scenario', choices=['sidebar', 'settings', 'books', 'longevity'], default='sidebar')
    parser.add_argument('--repetitions', type=int, choices=[1,3], default=3)
    parser.add_argument('--view', type=int, choices=range(4), default=0)
    parser.add_argument('--template', default='Time Profiler')
    args = parser.parse_args()
    if args.variant and not args.diagnostics:
        parser.error('Isolation requires --diagnostics')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = args.xctestrun.resolve()
    config = plistlib.loads(source.read_bytes())
    def absolute(value):
        if isinstance(value, str):
            return value.replace('__TESTROOT__', str(source.parent))
        if isinstance(value, list):
            return [absolute(item) for item in value]
        if isinstance(value, dict):
            return {key: absolute(item) for key, item in value.items()}
        return value
    config = absolute(config)
    for configuration in config['TestConfigurations']:
        for target in configuration['TestTargets']:
            target['OnlyTestIdentifiers'] = ['DevicePerformanceTests/' + ('testLongSessionProfile' if args.scenario == 'longevity' else 'testMenuProfile')]
            target['DefaultTestExecutionTimeAllowance'] = 4500
            target['MaximumTestExecutionTimeAllowance'] = 4800
            target['UITargetAppPerformanceAntipatternCheckerEnabled'] = False
            # Prevent test video encoding from competing with the app's render work.
            target['PreferredScreenCaptureFormat'] = 'screenshots'
            target['SystemAttachmentLifetime'] = 'keepNever'
            for key in ['EnvironmentVariables', 'TestingEnvironmentVariables', 'UITargetAppEnvironmentVariables']:
                target.setdefault(key, {}).pop('DYLD_INSERT_LIBRARIES', None)
            target['EnvironmentVariables'].update({
                'VERIFY_DEVICE_PERFORMANCE': '1',
                'PERF_DIAGNOSTICS': '1' if args.diagnostics else '0',
                'PERF_VARIANT': args.variant or '', 'PERF_SCENARIO': args.scenario,
                'PERF_VIEW': str(args.view), 'PERF_REPETITIONS': str(args.repetitions),
            })
            if args.app:
                target['UITargetAppPath'] = str(args.app.resolve())
                target['DependentProductPaths'] = [str(args.app.resolve()), target['TestHostPath']]
    app_path = Path(config['TestConfigurations'][0]['TestTargets'][0]['UITargetAppPath'])
    info = plistlib.loads((app_path/'Info.plist').read_bytes())
    executable = app_path/info['CFBundleExecutable']
    sections = subprocess.check_output(['otool', '-l', str(executable)], text=True)
    if '__llvm_prf' in sections or '__llvm_cov' in sections:
        raise SystemExit('The app contains coverage instrumentation. Rebuild before profiling.')
    test_file = output / 'run.xctestrun'
    test_file.write_bytes(plistlib.dumps(config))
    manifest = {
        'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
        'bundle_version': info.get('CFBundleVersion'),
        'automatic_capture': 'screenshots, keepNever',
        'coverage_sections_present': False,
        'started': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'device': args.device,
        'category': 'isolation' if args.variant else ('markers' if args.diagnostics else 'ordinary-release'),
        'variant': args.variant, 'scenario': args.scenario, 'view': args.view,
        'template': args.template, 'presses': f'{args.repetitions} blocks; 20 steady + 20 burst per block',
        'latency_boundary': 'App-delivered input to focus notification; not input-to-photon',
        'xctestrun_sha256': hashlib.sha256(test_file.read_bytes()).hexdigest(),
    }
    if args.scenario == 'longevity':
        manifest['presses'] = '20 minutes of Settings cycles; 40 presses; 45 minutes ambient; 40 presses'
    target = config['TestConfigurations'][0]['TestTargets'][0]
    test_bundle = Path(target['TestBundlePath'].replace('__TESTHOST__', target['TestHostPath']))
    test_info = plistlib.loads((test_bundle/'Info.plist').read_bytes())
    test_executable = test_bundle/test_info['CFBundleExecutable']
    manifest['test_executable_sha256'] = hashlib.sha256(test_executable.read_bytes()).hexdigest()
    experiment = output.parent/'experiment.json'
    if experiment.exists():
        (output/'experiment.json').write_bytes(experiment.read_bytes())
        manifest['experiment_sha256'] = hashlib.sha256(experiment.read_bytes()).hexdigest()
    log_path = output / 'test.log'
    recorder = None
    with log_path.open('w') as log, (output / 'trace.log').open('w') as trace_log:
        test = subprocess.Popen([
            'xcodebuild', 'test-without-building', '-xctestrun', str(test_file),
            '-destination', f'id={args.device}', '-parallel-testing-enabled', 'NO',
            '-collect-test-diagnostics', 'never',
            '-resultBundlePath', str(output / 'test.xcresult'),
        ], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 240
            while test.poll() is None and time.monotonic() < deadline:
                text = log_path.read_text(errors='replace')
                if 'PERFORMANCE_READY' in text:
                    process_file = output / 'processes.json'
                    run(['xcrun', 'devicectl', 'device', 'info', 'processes',
                         '--device', args.device, '--json-output', str(process_file)],
                        stdout=trace_log, stderr=subprocess.STDOUT)
                    processes = json.loads(process_file.read_text())['result']['runningProcesses']
                    pid = next(p['processIdentifier'] for p in processes
                               if p.get('executable', '').endswith('/Bookworms'))
                    manifest['pid'] = pid
                    recorder = subprocess.Popen([
                        'xcrun', 'xctrace', 'record', '--template', args.template,
                        '--instrument', 'Points of Interest', '--instrument', 'Hitches',
                        *(['--instrument', 'Activity Monitor'] if args.scenario == 'longevity' else []),
                        '--device', args.trace_device,
                        '--attach', str(pid), '--time-limit', '4400s' if args.scenario == 'longevity' else '240s',
                        '--output', str(output / 'recording.trace'),
                    ], stdout=trace_log, stderr=subprocess.STDOUT)
                    break
                time.sleep(1)
            if recorder is None:
                raise RuntimeError('Test did not reach profiling readiness; inspect test.log')
            deadline = time.monotonic() + (4400 if args.scenario == 'longevity' else 300)
            while test.poll() is None and time.monotonic() < deadline:
                if 'PERFORMANCE_FINISHED' in log_path.read_text(errors='replace'):
                    break
                if recorder.poll() is not None:
                    raise RuntimeError('Instruments exited before the sequence finished; inspect trace.log')
                time.sleep(1)
            if recorder.poll() is None:
                recorder.send_signal(signal.SIGINT)
                recorder.wait(timeout=150)
            if test.poll() is None:
                test.wait(timeout=90)
            manifest['test_exit'] = test.returncode
        finally:
            if recorder is not None and recorder.poll() is None:
                recorder.send_signal(signal.SIGINT)
                try:
                    recorder.wait(timeout=150)
                except subprocess.TimeoutExpired:
                    recorder.terminate()
            if test.poll() is None:
                test.terminate()
            manifest['trace_exit'] = recorder.returncode if recorder else None
            (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    if manifest['test_exit'] != 0 or manifest['trace_exit'] != 0:
        raise SystemExit('Recording or test failed; this run is not passing evidence.')
    print(f'Completed {output}', flush=True)


if __name__ == '__main__':
    main()
