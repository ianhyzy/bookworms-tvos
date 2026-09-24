#!/usr/bin/env python3
"""Compare installed local summarizers using existing reports, never rerunning tests."""
import importlib.util
import json
from pathlib import Path
import subprocess
import threading
import time

spec = importlib.util.spec_from_file_location("worker", Path(__file__).with_name("test-worker.py"))
w = importlib.util.module_from_spec(spec); spec.loader.exec_module(w)
LMS = Path.home() / ".lmstudio/bin/lms"


def main():
    output = w.ROOT / ".local/test-worker-benchmark" / time.strftime("%Y%m%d-%H%M%S")
    output.mkdir(parents=True)
    reports = []
    for path in (w.ROOT / ".local/test-results").glob("*/report.json"):
        try:
            reports.append((path, json.loads(path.read_text())))
        except (ValueError, OSError):
            pass
    passed = next((p, d) for p, d in reports if d.get("status") == "passed")
    failed = next((p, d) for p, d in reports if any(t.get("result") == "Failed" for r in d.get("runs", []) for t in r.get("tests", {}).values()))
    incomplete = next((p, d) for p, d in reports if not any(r.get("tests") for r in d.get("runs", [])))
    cases = []
    for name, (path, report), status in [("pass", passed, "passed"), ("assertion", failed, "failed"), ("incomplete", incomplete, "blocked")]:
        failures = report.get("failures", []) + [f for run in report.get("runs", []) for f in run.get("failures", [])]
        if status == "blocked":
            failures = ["Incomplete verification: no test outcomes available."] + failures
        cases.append({"case": name, "source_report": str(path), "status": status, "failures": failures,
            "runs": [{"nonpassing": {k: v for k, v in r.get("tests", {}).items() if v.get("result") != "Passed"}} for r in report.get("runs", [])]})
    (output / "cases.json").write_text(json.dumps(cases, indent=2) + "\n")
    inventory = w.local_request("/api/v1/models")
    (output / "models-before.json").write_text(json.dumps(inventory, indent=2) + "\n")
    # Only idle local instances may be unloaded to make room for Xcode.
    ps = json.loads(subprocess.check_output([str(LMS), "ps", "--json"], text=True))
    if any(m.get("status") != "idle" or m.get("queued", 0) for m in ps):
        raise SystemExit("Blocked: model is serving another request")
    for m in ps:
        subprocess.run([str(LMS), "unload", m["identifier"]], check=True)
    results = []
    for model in ["google/gemma-4-e4b", "google/gemma-4-12b"]:
        subprocess.run([str(LMS), "load", model, "--context-length", "8192", "--parallel", "1", "--identifier", model, "--ttl", "300", "-y"], check=True)
        memory = []
        stop = threading.Event()
        def sample():
            while not stop.is_set():
                pressure = subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], capture_output=True, text=True).stdout.strip()
                vm = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
                memory.append({"time": time.time(), "pressure_level": pressure, "vm_stat": vm})
                stop.wait(2)
        thread = threading.Thread(target=sample); thread.start()
        try:
            for case in cases:
                started = time.monotonic()
                record = {"model": model, "case": case["case"]}
                try:
                    record["output"] = w.summarize(case, model)
                    record["schema_and_identifiers_valid"] = True
                except Exception as error:
                    record["error"] = str(error)
                    record["schema_and_identifiers_valid"] = False
                record["elapsed_seconds"] = time.monotonic() - started
                results.append(record)
                (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
                print(model, case["case"], record["schema_and_identifiers_valid"], round(record["elapsed_seconds"], 1), flush=True)
        finally:
            stop.set(); thread.join()
            (output / (model.split("/")[-1] + "-memory.json")).write_text(json.dumps(memory, indent=2) + "\n")
            subprocess.run([str(LMS), "unload", model], check=True)
    print(output)


if __name__ == "__main__":
    main()
