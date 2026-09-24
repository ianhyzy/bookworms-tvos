#!/usr/bin/env python3
"""Prepare, validate, or explicitly upload a reproducible tvOS release candidate."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def output(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def source_files():
    names = subprocess.check_output(
        ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT)
    return sorted(set(n.decode() for n in names.split(b'\0') if n))


def source_digest():
    digest = hashlib.sha256()
    for name in source_files():
        path = ROOT / name
        if path.is_file():
            digest.update(name.encode() + b'\0' + path.read_bytes() + b'\0')
    return digest.hexdigest()


def run(args, log):
    print('Running:', args[0], '— log:', log, flush=True)
    with log.open('w') as handle:
        subprocess.run(args, cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT, check=True)


def save(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def verify(candidate, data):
    run(['python3', 'scripts/verify-release-archive.py', str(candidate / 'Bookworms.xcarchive'),
         '--expected-version', data['version'], '--expected-build', str(data['build'])],
        candidate / 'verification.json')


def authentication():
    values = [os.environ.get(k) for k in
              ('ASC_KEY_PATH', 'ASC_KEY_ID', 'ASC_ISSUER_ID')]
    if any(values) and not all(values):
        raise SystemExit('Set all three ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID, or none.')
    if all(values):
        key = Path(values[0]).expanduser().resolve()
        if not key.is_file() or key.is_relative_to(ROOT):
            raise SystemExit('ASC_KEY_PATH must point to a private key outside this repository.')
        return ['-authenticationKeyPath', str(key), '-authenticationKeyID', values[1],
                '-authenticationKeyIssuerID', values[2]]
    return []


def prepare(args):
    spec = ROOT / 'project.yml'
    text = spec.read_text()
    version = re.search(r"MARKETING_VERSION: '([0-9]+\.[0-9]+\.[0-9]+)'", text).group(1)
    current = int(re.search(r"CURRENT_PROJECT_VERSION: '(\d+)'", text).group(1))
    build = max(current, args.highest_uploaded_build) + 1
    if not 1 <= build <= 9999:
        raise SystemExit('Build number must be between 1 and 9999.')
    timestamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    candidate = ROOT / '.local/releases' / f'{version}-{build}-{timestamp}'
    candidate.mkdir(parents=True, exist_ok=False)
    data = dict(version=version, build=build, highestUploadedBuild=args.highest_uploaded_build,
                status='preparing', sourceCommit=output('git', 'rev-parse', 'HEAD'),
                xcode=output('xcodebuild', '-version'), xcodegen=output('xcodegen', '--version'))
    save(candidate / 'candidate.json', data)
    spec.write_text(re.sub(r"CURRENT_PROJECT_VERSION: '\d+'",
                          f"CURRENT_PROJECT_VERSION: '{build}'", text, count=1))
    run(['xcodegen', 'generate'], candidate / 'generate.log')
    data['sourceDigest'] = source_digest()
    data['sourceStatus'] = output('git', 'status', '--short')
    with tarfile.open(candidate / 'source-snapshot.tar.gz', 'w:gz') as snapshot:
        for name in source_files():
            if (ROOT / name).is_file():
                snapshot.add(ROOT / name, arcname=name)
    save(candidate / 'candidate.json', data)
    run(['python3', 'scripts/test-local.py'], candidate / 'tests.log')
    data['tests'] = 'passed; result bundle path recorded in tests.log'
    save(candidate / 'candidate.json', data)
    run(['xcodebuild', '-project', 'Bookworms.xcodeproj', '-scheme', 'BookwormsDevice',
         '-configuration', 'Release', '-destination', 'generic/platform=tvOS',
         'CLANG_ENABLE_CODE_COVERAGE=NO', '-derivedDataPath', '.build-release',
         '-archivePath', str(candidate / 'Bookworms.xcarchive'), '-allowProvisioningUpdates',
         *authentication(), 'archive'], candidate / 'build.log')
    if data['sourceDigest'] != source_digest():
        raise SystemExit('Source changed during preparation. Prepare a new candidate.')
    verify(candidate, data)
    data['status'] = 'prepared'
    save(candidate / 'candidate.json', data)
    print('Candidate:', candidate, flush=True)


def distribute(args):
    candidate = args.candidate.expanduser().resolve()
    data = json.loads((candidate / 'candidate.json').read_text())
    if data['status'] not in ('prepared', 'validated'):
        raise SystemExit('Candidate is not ready or was already uploaded. Inspect candidate.json.')
    if args.command == 'upload':
        if data['status'] != 'validated':
            raise SystemExit('Run validate on this candidate before uploading.')
        if output('git', 'status', '--porcelain'):
            raise SystemExit('Commit the candidate sources before uploading; working tree is dirty.')
        if source_digest() != data['sourceDigest']:
            raise SystemExit('Candidate sources changed. Prepare and validate a new candidate.')
    verify(candidate, data)
    uploading = args.command == 'upload'
    # Xcode requires the upload destination for validation; the validation method
    # selects its validate-only workflow rather than App Store distribution.
    options = dict(method='app-store-connect' if uploading else 'validation',
                   destination='upload',
                   teamID='KSZ7QR8Y88', signingStyle='automatic',
                   manageAppVersionAndBuildNumber=False, uploadSymbols=True,
                   iCloudContainerEnvironment='Production')
    option_path = candidate / (args.command + '-options.plist')
    option_path.write_bytes(plistlib.dumps(options))
    # Mark uncertain uploads before the request, so an interrupted command cannot silently retry.
    if uploading:
        data['status'] = 'upload-requested'
        data['uploadCommit'] = output('git', 'rev-parse', 'HEAD')
        save(candidate / 'candidate.json', data)
    run(['xcodebuild', '-exportArchive', '-archivePath', str(candidate / 'Bookworms.xcarchive'),
         '-exportOptionsPlist', str(option_path), '-exportPath', str(candidate / args.command),
         '-allowProvisioningUpdates', *authentication()], candidate / (args.command + '.log'))
    data['status'] = 'uploaded; Apple processing pending' if uploading else 'validated'
    save(candidate / 'candidate.json', data)
    print(data['status'], flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prep = commands.add_parser('prepare', help='Increment, test, archive, and verify locally.')
    prep.add_argument('--highest-uploaded-build', type=int, required=True,
                      help='Highest build just checked in App Store Connect (0 for none).')
    for name in ('validate', 'upload'):
        command = commands.add_parser(name)
        command.add_argument('candidate', type=Path)
    args = parser.parse_args()
    authentication()
    if args.command == 'prepare':
        if args.highest_uploaded_build < 0:
            parser.error('--highest-uploaded-build cannot be negative')
        prepare(args)
    else:
        distribute(args)


if __name__ == '__main__':
    main()
