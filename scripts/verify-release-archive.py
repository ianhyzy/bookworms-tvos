#!/usr/bin/env python3
"""Check a local tvOS archive without uploading it or changing signing assets."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess


def plist(path):
    with path.open('rb') as source:
        return plistlib.load(source)


def run(*arguments):
    return subprocess.run(arguments, check=True, capture_output=True).stdout


def inspect_bundle(bundle):
    info = plist(bundle / 'Info.plist')
    sections = run('otool', '-l', str(bundle / info['CFBundleExecutable']))
    assert b'__llvm_prf' not in sections and b'__llvm_cov' not in sections, 'Release contains coverage instrumentation'
    run('codesign', '--verify', '--strict', str(bundle))
    entitlements = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', str(bundle)))
    manifest = plist(bundle / 'PrivacyInfo.xcprivacy')
    profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(bundle / 'embedded.mobileprovision')))
    assert info.get('CFBundleDisplayName'), 'Missing bundle display name'
    capabilities = info.get('UIRequiredDeviceCapabilities', [])
    assert (capabilities.get('arm64') is True if isinstance(capabilities, dict) else 'arm64' in capabilities), 'Missing required arm64 capability'
    if 'CloudKit' in entitlements.get('com.apple.developer.icloud-services', []):
        environment = entitlements.get('aps-environment')
        assert environment in ('development', 'production'), 'CloudKit requires the push environment entitlement'
        assert environment == profile['Entitlements'].get('aps-environment'), 'Push environment does not match provisioning profile'
    assert info['MinimumOSVersion'] == '26.0', 'Unexpected deployment target'
    assert info['CFBundleSupportedPlatforms'] == ['AppleTVOS'], 'Expected a tvOS device bundle'
    assert 'group.gay.ian.Bookworms' in entitlements['com.apple.security.application-groups']
    assert manifest['NSPrivacyTracking'] is False
    assert manifest['NSPrivacyTrackingDomains'] == []
    reasons = {item['NSPrivacyAccessedAPIType']: item['NSPrivacyAccessedAPITypeReasons']
               for item in manifest['NSPrivacyAccessedAPITypes']}
    return info, entitlements, {
        'bundle': info['CFBundleIdentifier'],
        'displayName': info.get('CFBundleDisplayName', info['CFBundleName']),
        'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'],
        'minimumOS': info['MinimumOSVersion'],
        'requiredReasonAPIs': reasons,
        'signingEntitlements': entitlements,
        'profileExpires': profile['ExpirationDate'].isoformat(),
        'developmentSigned': bool(entitlements.get('get-task-allow')),
        'signatureVerified': True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--expected-version', required=True)
    parser.add_argument('--expected-build', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.expected_version):
        parser.error('Expected version must have three numeric components, such as 1.0.0')
    if not re.fullmatch(r'[1-9][0-9]{0,3}', args.expected_build):
        parser.error('Expected build must be an integer from 1 through 9999')
    archive_info = plist(args.archive / 'Info.plist')
    app = args.archive / 'Products' / archive_info['ApplicationProperties']['ApplicationPath']
    info, entitlements, app_report = inspect_bundle(app)
    assert info['CFBundleShortVersionString'] == args.expected_version, 'Unexpected marketing version'
    assert info['CFBundleVersion'] == args.expected_build, 'Unexpected build number'
    assert info['CFBundleIdentifier'] == 'gay.ian.Bookworms'
    assert info['CFBundleDisplayName'] == 'Bookworms - eBook Display'
    assert (app / 'Assets.car').is_file(), 'Missing compiled artwork'
    assert 'iCloud.gay.ian.Bookworms' in entitlements['com.apple.developer.icloud-container-identifiers']
    assert entitlements['com.apple.developer.icloud-services'] == ['CloudKit']
    assert app_report['requiredReasonAPIs'] == {
        'NSPrivacyAccessedAPICategoryUserDefaults': ['CA92.1'],
        'NSPrivacyAccessedAPICategoryFileTimestamp': ['C617.1'],
    }
    extensions = list((app / 'PlugIns').glob('*.appex'))
    assert len(extensions) == 1, 'Expected exactly one Top Shelf extension'
    extension_info, _, extension_report = inspect_bundle(extensions[0])
    assert extension_info['CFBundleIdentifier'] == 'gay.ian.Bookworms.TopShelf'
    assert extension_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.tv-top-shelf'
    assert extension_report['requiredReasonAPIs'] == {}, 'Review new extension API use'
    for key in ('CFBundleVersion', 'CFBundleShortVersionString'):
        assert info[key] == extension_info[key], 'App and extension versions differ'
    assert not list(app.rglob('*.xctest')), 'Tests must not be packaged in the app'
    print(json.dumps({'app': app_report, 'extension': extension_report,
                      'scope': 'Local packaging and signature checks; not App Store validation.'}, indent=2))


if __name__ == '__main__':
    main()
