#!/usr/bin/env python3
"""Pass an existing 1Password CWA login to a Debug build without logging secrets."""
import argparse
import os
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--username-ref", required=True, help="1Password reference to the username field")
parser.add_argument("--password-ref", required=True, help="1Password reference to the password field")
parser.add_argument("--server", required=True)
parser.add_argument("--device")
parser.add_argument("--simulator")
args = parser.parse_args()
if bool(args.device) == bool(args.simulator):
    parser.error("Choose a device or simulator.")
if not (args.username_ref.startswith("op://") and args.password_ref.startswith("op://")):
    parser.error("Use op:// secret references.")


def read_secret(reference):
    """Reads one 1Password field, so other secrets in the item never reach this process."""
    result = subprocess.run(["op", "read", reference], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit("Unlock 1Password and try again.")
    return result.stdout.removesuffix("\n")


values = {"CWA_BOOTSTRAP_SERVER": args.server, "CWA_BOOTSTRAP_USERNAME": read_secret(args.username_ref),
          "CWA_BOOTSTRAP_PASSWORD": read_secret(args.password_ref)}
environment = os.environ.copy()
prefix = "SIMCTL_CHILD_" if args.simulator else "DEVICECTL_CHILD_"
environment.update({prefix + key: value for key, value in values.items()})
command = (["xcrun", "simctl", "launch", "--terminate-running-process", args.simulator, "gay.ian.Bookworms"] if args.simulator else
    ["xcrun", "devicectl", "device", "process", "launch", "--terminate-existing", "--device", args.device, "gay.ian.Bookworms"])
result = subprocess.run(command, env=environment, capture_output=True, text=True)
if result.returncode:
    raise SystemExit("App launch failed. Check the device connection.")
print("CWA login supplied privately. Check the app's source status.")
