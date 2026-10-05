#!/usr/bin/env python3
"""Load the saved real-library snapshot into a simulator and launch the app without credentials.

`.local/hardcover-snapshot/` holds a copy of a Debug simulator's library, social cache, covers,
and preferences after one authorized sync (see docs/DEVELOPMENT.md). This script installs nothing:
install the Debug app first. It never reads or passes a credential, so the app shows the cached
library and, through `--cached-social-preview`, the cached social data without network requests.
"""

import argparse
import pathlib
import subprocess
import sys

BUNDLE = "gay.ian.Bookworms"
ROOT = pathlib.Path(__file__).resolve().parent.parent
SNAPSHOT = ROOT / ".local" / "hardcover-snapshot"

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--simulator", default="booted", help="Simulator UDID; defaults to the booted one")
parser.add_argument(
    "--app-arg", action="append", default=[],
    help="Launch argument for the app, such as --app-arg=--start-view=yearInReview; repeatable")
args = parser.parse_args()

if not (SNAPSHOT / "Bookworms" / "sources.json").exists():
    sys.exit(f"No snapshot at {SNAPSHOT}. Run one authorized sync first; see docs/DEVELOPMENT.md.")


def run(*command: str) -> str:
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout.strip()


try:
    container = pathlib.Path(run("xcrun", "simctl", "get_app_container", args.simulator, BUNDLE, "data"))
except subprocess.CalledProcessError:
    sys.exit("Install the Debug app on the simulator first.")

subprocess.run(["xcrun", "simctl", "terminate", args.simulator, BUNDLE], capture_output=True)
caches = container / "Library" / "Caches" / "Bookworms"
caches.mkdir(parents=True, exist_ok=True)
run("rsync", "-a", "--delete", f"{SNAPSHOT / 'Bookworms'}/", f"{caches}/")
preferences = SNAPSHOT / "Preferences" / f"{BUNDLE}.plist"
if preferences.exists():
    # Import through the simulator's preferences daemon, which would ignore a copied file.
    run("xcrun", "simctl", "spawn", args.simulator, "defaults", "import", BUNDLE, str(preferences))
run("xcrun", "simctl", "launch", args.simulator, BUNDLE, "--cached-social-preview", *args.app_arg)
print("Launched with the saved library and cached social data.")
