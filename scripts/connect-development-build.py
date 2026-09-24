#!/usr/bin/env python3
"""Connect a development install using a 1Password secret reference."""

import argparse
import os
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--secret-ref", required=True, help="1Password reference; never pass a literal token")
parser.add_argument("--simulator")
parser.add_argument("--device")
parser.add_argument("--credential", choices=["hardcover", "gemini"], default="hardcover")
args = parser.parse_args()
if bool(args.simulator) == bool(args.device):
    parser.error("Specify either --simulator or --device.")
if not args.secret_ref.startswith("op://"):
    parser.error("Use an op:// secret reference.")

result = subprocess.run(["op", "read", args.secret_ref], capture_output=True, text=True)
if result.returncode:
    raise SystemExit("1Password could not read the credential. Unlock it and try again.")
token = result.stdout.strip()
if token.lower().startswith("bearer "):
    token = token[7:].strip()
if not token or any(char.isspace() for char in token):
    raise SystemExit("The credential format is invalid.")

if args.credential == "hardcover" and (not token.startswith("hc_pat_") or len(token) <= 7):
    raise SystemExit("Use a new Hardcover Personal Access Token (hc_pat_), not a legacy token.")

variable = "HARDCOVER_BOOTSTRAP_TOKEN" if args.credential == "hardcover" else "GEMINI_BOOTSTRAP_TOKEN"
if args.simulator:
    environment = os.environ.copy()
    environment["SIMCTL_CHILD_" + variable] = token
    result = subprocess.run(
        ["xcrun", "simctl", "launch", "--terminate-running-process", args.simulator, "gay.ian.Bookworms"],
        env=environment, capture_output=True, text=True,
    )
else:
    environment = os.environ.copy()
    environment["DEVICECTL_CHILD_" + variable] = token
    result = subprocess.run(
        ["xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
         "--terminate-existing", "gay.ian.Bookworms"],
        env=environment, capture_output=True, text=True,
    )

# Tool output can echo environment values. Report only the exit status.
if result.returncode:
    raise SystemExit("The development app could not be launched. Inspect the device connection without credentials.")
print("Development app launched with the credential supplied privately. Verify account connection in the app.")
