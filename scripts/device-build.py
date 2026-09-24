#!/usr/bin/env python3
"""Build or test on Apple TV, then remove this project's UI test runner."""

import argparse
import json
import tempfile
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
APP_ID = "gay.ian.Bookworms"
RUNNER_ID = "gay.ian.BookwormsUITests.xctrunner"
# Ignored per-machine defaults: {"device": "APPLE_TV_UDID", "team": "TEAM_ID"}.
LOCAL_DEFAULTS = ROOT / ".local/device-build.json"


def run(arguments):
    subprocess.run(arguments, cwd=ROOT, check=True)


def clean_test_runner(device):
    with tempfile.TemporaryDirectory(prefix="bookworms-apps-") as directory:
        inventory = Path(directory) / "apps.json"
        run(["xcrun", "devicectl", "device", "info", "apps", "--device", device,
             "--json-output", str(inventory)])
        apps = json.loads(inventory.read_text())["result"]["apps"]
        if any(app["bundleIdentifier"] == RUNNER_ID for app in apps):
            run(["xcrun", "devicectl", "device", "uninstall", "app", "--device", device, RUNNER_ID])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help=f"Apple TV UDID shown in Xcode; defaults to {LOCAL_DEFAULTS.name}")
    parser.add_argument("--team", help=f"Apple development team ID; defaults to {LOCAL_DEFAULTS.name}")
    parser.add_argument("--test", action="store_true", help="Run tests instead of installing a normal build")
    parser.add_argument("--only-testing", help="Optional test target or method")
    parser.add_argument("--test-plan", choices=["Local", "Unit", "Device"], default="Local",
                        help="Choose Device for opt-in live-library checks")
    parser.add_argument("--configuration", choices=["Debug", "Release"], help="Defaults to Release for installs and Debug for tests")
    parser.add_argument("--start-view", help="Optional view to launch directly into (e.g. shared)")
    args = parser.parse_args()
    defaults = json.loads(LOCAL_DEFAULTS.read_text()) if LOCAL_DEFAULTS.exists() else {}
    args.device = args.device or defaults.get("device")
    args.team = args.team or defaults.get("team")
    if not args.device or not args.team:
        parser.error(f"Pass --device and --team, or save them in {LOCAL_DEFAULTS.relative_to(ROOT)}")
    configuration = args.configuration or ("Debug" if args.test else "Release")
    if args.only_testing and not args.test:
        parser.error("--only-testing requires --test")
    command = ["xcodebuild", "-project", "Bookworms.xcodeproj", "-scheme", "BookwormsDevice",
               "-configuration", configuration, "-destination", f"id={args.device}", "-derivedDataPath", ".build-device",
               f"DEVELOPMENT_TEAM={args.team}"]
    if configuration == "Release":
        command += ["CLANG_ENABLE_CODE_COVERAGE=NO"]
        if args.test:
            command += ["-enableCodeCoverage", "NO"]
    if args.test:
        command += ["-parallel-testing-enabled", "NO", "ENABLE_TESTABILITY=YES", "-testPlan", args.test_plan]
        if args.only_testing:
            command += [f"-only-testing:{args.only_testing}"]
    if not args.test:
        # Local installs share the release identity and data, but have distinct Home Screen branding.
        command += ["ASSETCATALOG_COMPILER_APPICON_NAME=Local App Icon",
                    "INFOPLIST_KEY_CFBundleDisplayName=Bookworms Local"]
    command.append("test" if args.test else "build")
    result = 0
    try:
        run(command)
        if not args.test:
            if configuration == "Release":
                binary = ROOT / f".build-device/Build/Products/{configuration}-appletvos/Bookworms.app/Bookworms"
                sections = subprocess.check_output(["otool", "-l", str(binary)], text=True)
                if "__llvm_prf" in sections or "__llvm_cov" in sections:
                    raise SystemExit("Refusing to install a coverage-instrumented Release app.")
            # Keep the bundle ID stable so installation preserves app data and Keychain access.
            run(["xcrun", "devicectl", "device", "install", "app", "--device", args.device,
                 str(ROOT / f".build-device/Build/Products/{configuration}-appletvos/Bookworms.app")])
    except subprocess.CalledProcessError as error:
        result = error.returncode
    finally:
        try:
            clean_test_runner(args.device)
        except subprocess.CalledProcessError:
            print("Test-runner cleanup failed. Check the device connection and installed apps.", file=sys.stderr)
            result = result or 1
    if not result:
        launch_command = ["xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
                          "--terminate-existing", APP_ID]
        if args.start_view:
            launch_command.append(f"--start-view={args.start_view}")
        run(launch_command)
    return result


if __name__ == "__main__":
    sys.exit(main())
