#!/usr/bin/env python3
"""Pass an existing 1Password CWA login to a Debug build without logging secrets."""
import argparse
import json
import os
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--item", required=True)
parser.add_argument("--server", required=True)
parser.add_argument("--device")
parser.add_argument("--simulator")
args = parser.parse_args()
if bool(args.device) == bool(args.simulator):
    parser.error("Choose a device or simulator.")
result = subprocess.run(["op", "item", "get", args.item, "--format", "json"], capture_output=True, text=True)
if result.returncode:
    raise SystemExit("Unlock 1Password and try again.")
fields = {field["id"]: field.get("value", "") for field in json.loads(result.stdout)["fields"]}
values = {"CWA_BOOTSTRAP_SERVER": args.server, "CWA_BOOTSTRAP_USERNAME": fields["username"], "CWA_BOOTSTRAP_PASSWORD": fields["password"]}
environment = os.environ.copy()
prefix = "SIMCTL_CHILD_" if args.simulator else "DEVICECTL_CHILD_"
environment.update({prefix + key: value for key, value in values.items()})
command = (["xcrun", "simctl", "launch", "--terminate-running-process", args.simulator, "gay.ian.Bookworms"] if args.simulator else
    ["xcrun", "devicectl", "device", "process", "launch", "--terminate-existing", "--device", args.device, "gay.ian.Bookworms"])
result = subprocess.run(command, env=environment, capture_output=True, text=True)
if result.returncode:
    raise SystemExit("App launch failed. Check the device connection.")
print("CWA login supplied privately. Check the app's source status.")
