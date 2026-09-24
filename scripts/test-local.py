#!/usr/bin/env python3
"""Run offline tests on disposable Apple TV simulators and retain auditable evidence."""

import argparse
import datetime
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
REMAINING_CHECKS = [
    "Live Hardcover/CWA authentication and response compatibility (separate read-only checks).",
    "Physical Apple TV performance, memory pressure, and Siri Remote gestures.",
    "TV-distance readability, motion comfort, and actual VoiceOver experience.",
    "Home Screen publishing, signed-update credentials, and production CloudKit restoration.",
]


class VerificationError(RuntimeError):
    """Required evidence could not be obtained or validated."""


def offline_environment():
    """Remove credential bootstrap and live-check controls inherited from the shell."""
    environment = os.environ.copy()
    for key in tuple(environment):
        name = key
        while name.startswith(("TEST_RUNNER_", "SIMCTL_CHILD_")):
            name = name.removeprefix("TEST_RUNNER_").removeprefix("SIMCTL_CHILD_")
        if name.startswith(("HARDCOVER_BOOTSTRAP_", "CWA_BOOTSTRAP_", "GEMINI_BOOTSTRAP_")) or name.startswith("VERIFY_") or any(word in name for word in ("API_KEY", "ACCESS_TOKEN", "AUTH_TOKEN")):
            del environment[key]
    environment.setdefault("GIT_CONFIG_GLOBAL", "/dev/null")
    return environment


def run(arguments, **kwargs):
    kwargs.setdefault("env", offline_environment())
    return subprocess.run(arguments, cwd=ROOT, check=True, **kwargs)


def command_text(arguments):
    return run(arguments, capture_output=True, text=True).stdout.strip()


def command_json(arguments, destination=None):
    value = json.loads(command_text(arguments))
    if destination:
        save_json(destination, value)
    return value


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def source_identity():
    """Include tracked and untracked source, while excluding ignored build artifacts."""
    names = run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], capture_output=True
    ).stdout.split(b"\0")
    digest = hashlib.sha256()
    for name in sorted(set(n for n in names if n)):
        path = ROOT / os.fsdecode(name)
        if path.is_file():
            digest.update(name + b"\0" + path.read_bytes() + b"\0")
    return {
        "commit": command_text(["git", "rev-parse", "HEAD"]),
        "status": command_text(["git", "status", "--porcelain"]),
        "sha256": digest.hexdigest(),
    }


def strip_swift_literals(source):
    """Hide literals and comments before finding the repository's XCTest declarations."""
    return re.sub(
        r'//[^\n]*|/\*[\s\S]*?\*/|(?:#+)?"""[\s\S]*?"""(?:#+)?|(?:#+)?"(?:\\.|[^"\\])*"(?:#+)?',
        lambda match: " " * len(match.group()), source,
    )


def discover_required_tests(root, plan_name):
    """Read XCTest methods selected by the plan, so newly added tests are mandatory.

    The repository uses explicit XCTestCase subclasses with zero-argument test
    methods. New test frameworks or conditional test declarations require extending
    discovery; actual result enumeration is also checked for unexpected tests.
    """
    plan = json.loads((root / "TestPlans" / (plan_name + ".xctestplan")).read_text())
    required = set()
    for target in plan["testTargets"]:
        if target.get("enabled", True) is False:
            continue
        target_name = target["target"]["name"]
        available = set()
        for path in sorted((root / target_name).rglob("*.swift")):
            source = strip_swift_literals(path.read_text())
            declarations = list(re.finditer(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b[^\{]*\{", source))
            for declaration in declarations:
                depth = 1
                end = declaration.end()
                while end < len(source) and depth:
                    depth += (source[end] == "{") - (source[end] == "}")
                    end += 1
                if depth:
                    raise VerificationError(f"Unbalanced XCTest declaration in {path}")
                body = source[declaration.end():end - 1]
                for method in re.findall(r"\bfunc\s+(test\w+)\s*\(\s*\)", body):
                    available.add(f"{declaration.group(1)}/{method}")
        if not available:
            raise VerificationError(f"No XCTest methods discovered in {target_name}")
        selected = target.get("selectedTests")
        skipped = target.get("skippedTests", [])
        for selection in (selected or []) + skipped:
            normalized = selection.removesuffix("()")
            if not any(test == normalized or test.startswith(normalized + "/") for test in available):
                raise VerificationError(f"Test plan references undiscovered test {target_name}/{selection}")
        for test in available:
            def matches(selection):
                selection = selection.removesuffix("()")
                return test == selection or test.startswith(selection + "/")
            if selected is not None and not any(matches(s) for s in selected):
                continue
            if any(matches(s) for s in skipped):
                continue
            required.add(target_name + "/" + test)
    if not required:
        raise VerificationError("The selected plan contains no required tests")
    return sorted(required)


def test_outcomes(tree):
    outcomes = {}

    def visit(node, bundle=None):
        if node.get("nodeType") in ("Unit test bundle", "UI test bundle"):
            bundle = node["name"].removesuffix(".xctest")
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier", "").removesuffix("()")
            if not bundle or not identifier:
                raise VerificationError("Test case is missing its bundle or identifier")
            key = bundle + "/" + identifier
            if key in outcomes:
                raise VerificationError(f"Duplicate test result: {key}")
            outcomes[key] = {"result": node.get("result", "unknown"),
                             "duration_seconds": node.get("durationInSeconds")}
        for child in node.get("children", []):
            visit(child, bundle)

    if not isinstance(tree.get("testNodes"), list):
        raise VerificationError("Test enumeration is missing testNodes")
    for node in tree["testNodes"]:
        visit(node)
    return outcomes


def validate_results(summary, tree, required, exit_code):
    outcomes = test_outcomes(tree)
    failures = []
    if exit_code:
        failures.append(f"xcodebuild exited with status {exit_code}")
    if summary.get("result") != "Passed":
        failures.append(f"Result summary: {summary.get('result', 'missing')}")
    for field in ("failedTests", "skippedTests", "expectedFailures"):
        if summary.get(field) != 0:
            failures.append(f"Summary {field}: {summary.get(field, 'missing')}")
    missing = sorted(set(required) - outcomes.keys())
    unexpected = sorted(outcomes.keys() - set(required))
    if missing:
        failures.append("Required tests did not run: " + ", ".join(missing))
    if unexpected:
        failures.append("Result contains tests absent from source/plan discovery: " + ", ".join(unexpected))
    if summary.get("totalTestCount") != len(outcomes):
        failures.append("Summary test count does not match enumerated results")
    if summary.get("passedTests") != sum(t["result"] == "Passed" for t in outcomes.values()):
        failures.append("Summary pass count does not match enumerated results")
    for identifier, outcome in outcomes.items():
        if outcome["result"] != "Passed":
            failures.append(identifier + ": " + outcome["result"])
    if not outcomes:
        failures.append("Result contains no test cases")
    return outcomes, failures


def validate_coverage(coverage):
    if not isinstance(coverage, dict) or not isinstance(coverage.get("targets"), list):
        raise VerificationError("Coverage export is missing targets")
    app = next((t for t in coverage["targets"] if t.get("name") == "Bookworms.app"), None)
    if not app or not app.get("executableLines", 0):
        raise VerificationError("Coverage export has no executable Bookworms.app lines")
    executable, covered, fraction = app["executableLines"], app.get("coveredLines"), app.get("lineCoverage")
    if (type(executable) is not int or executable <= 0
            or type(covered) is not int or not 0 <= covered <= executable
            or type(fraction) not in (int, float) or not math.isfinite(fraction)
            or not 0 <= fraction <= 1 or not math.isclose(fraction, covered / executable, abs_tol=1e-6)):
        raise VerificationError("Coverage export has missing or inconsistent app line counts")
    return {"line_coverage": fraction,
            "covered_lines": covered, "executable_lines": executable}


def safe_name(value):
    return re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-")


def compare_screenshots(attachments, output, baseline):
    """Export stable references and comparisons without approving or replacing baselines."""
    manifest_path = attachments / "manifest.json"
    if not manifest_path.is_file():
        raise VerificationError("Attachment export did not produce manifest.json")
    screenshots = output / "screenshots"
    screenshots.mkdir()
    records = []
    seen = set()
    for test in json.loads(manifest_path.read_text()):
        test_name = safe_name(test["testIdentifier"].removesuffix("()"))
        for attachment in test.get("attachments", []):
            exported_name = attachment["exportedFileName"]
            if Path(exported_name).name != exported_name:
                raise VerificationError("Attachment path must be a filename")
            source = attachments / exported_name
            if source.suffix.lower() != ".png":
                continue
            if not source.is_file():
                raise VerificationError(f"Exported screenshot is missing: {exported_name}")
            title = re.sub(r"_\d+_[0-9A-Fa-f-]{36}\.png$", "", attachment["suggestedHumanReadableName"])
            name = test_name + "--" + safe_name(title.removesuffix(".png")) + ".png"
            if name in seen:
                raise VerificationError(f"Duplicate screenshot name; use unique attachment names: {name}")
            seen.add(name)
            current = screenshots / name
            shutil.copy2(source, current)
            reference = baseline / name if baseline else None
            digest = hashlib.sha256(current.read_bytes()).hexdigest()
            state = "missing_baseline"
            if reference and reference.is_file():
                state = "unchanged" if digest == hashlib.sha256(reference.read_bytes()).hexdigest() else "changed"
            records.append({"name": name, "test": test["testIdentifier"], "title": title,
                            "path": str(current), "baseline": str(reference) if reference else None,
                            "sha256": digest, "comparison": state})
    if baseline and baseline.is_dir():
        for reference in sorted(baseline.glob("*.png")):
            if reference.name not in seen:
                records.append({"name": reference.name, "title": reference.stem, "test": None,
                                "path": None, "baseline": str(reference), "sha256": None,
                                "comparison": "missing_current"})
    status = "review_pending" if any(r["comparison"] != "unchanged" for r in records) else "passed"
    if not records:
        status = "not_applicable"
    sections = ["<!doctype html><meta charset='utf-8'><title>Bookworms visual review</title>",
                "<style>body{font:16px system-ui;margin:2rem;background:#eee}section{margin-bottom:3rem}"
                ".pair{display:flex;gap:1rem}.pair figure{margin:0;width:50%}img{width:100%}</style>",
                "<h1>Screenshot review</h1><p>Byte comparisons flag changes for review. "
                "They do not judge visual correctness. This report never approves a baseline.</p>"]
    for record in records:
        sections.append(f"<section><h2>{html.escape(record['title'])}</h2><p>{html.escape(record['comparison'])}</p><div class='pair'>")
        for label, path in (("Approved baseline", record["baseline"]), ("Current", record["path"])):
            sections.append("<figure><figcaption>" + label + "</figcaption>")
            if path and Path(path).is_file():
                sections.append(f"<img alt='{label}' src='{html.escape(Path(path).as_uri(), quote=True)}'>")
            else:
                sections.append("<p>Screenshot missing.</p>")
            sections.append("</figure>")
        sections.append("</div></section>")
    (output / "visual-review.html").write_text("\n".join(sections))
    result = {"status": status, "comparison_method": "PNG byte SHA-256; visual review required for changes",
              "screenshots": records, "report": str(output / "visual-review.html")}
    save_json(output / "visual-review.json", result)
    return result


def inspect_results(result, output, required, exit_code, baseline=None):
    if not result.exists():
        raise VerificationError("xcodebuild did not create the required result bundle")
    # xcresulttool can populate caches inside the bundle. Keep its operations sequential.
    summary = command_json(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)],
                           output / "test-summary.json")
    tree = command_json(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result)],
                        output / "test-tree.json")
    outcomes, failures = validate_results(summary, tree, required, exit_code)
    evidence = {"tests": outcomes, "summary": summary, "failures": failures}
    try:
        coverage = command_json(["xcrun", "xccov", "view", "--report", "--json", str(result)], output / "coverage.json")
        evidence["coverage"] = validate_coverage(coverage)
    except (subprocess.CalledProcessError, ValueError, OSError, VerificationError) as error:
        failures.append("Coverage export failed: " + str(error))
    try:
        attachments = output / "attachments"
        with (output / "attachments.log").open("w") as log:
            run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                 "--output-path", str(attachments)], stdout=log, stderr=subprocess.STDOUT)
        evidence["visual_review"] = compare_screenshots(attachments, output, baseline)
        current_screenshots = [image for image in evidence["visual_review"]["screenshots"] if image.get("path")]
        if any(test.startswith("BookwormsUITests/") for test in required) and not current_screenshots:
            failures.append("UI suite produced no screenshot evidence")
    except (subprocess.CalledProcessError, ValueError, OSError, VerificationError) as error:
        failures.append("Attachment export failed: " + str(error))
    return evidence


def version_tuple(value):
    return tuple(int(part) for part in value.split("."))


def select_runtimes(inventory, requested):
    available = [r for r in inventory["runtimes"] if r.get("isAvailable") and "tvOS" in r["identifier"]]
    if requested:
        selected = []
        for version in requested:
            matches = [r for r in available if r["version"] == version or r["identifier"] == version]
            selected.append((version, matches[0] if matches else None))
        return selected
    if not available:
        return [("latest installed", None)]
    newest = max(available, key=lambda runtime: version_tuple(runtime["version"]))
    return [(newest["version"], newest)]


def mute_simulator_audio():
    """Disable Device Hub's tvOS audio output without changing Mac speaker volume."""
    framework = Path(command_text(["xcode-select", "-p"])).parent / "SharedFrameworks/DeviceKit.framework/Versions/A/DeviceKit"
    if not framework.is_file() or b"enableAudioOutput_tvOS" not in framework.read_bytes():
        raise VerificationError("Simulator audio control is unsupported by this Xcode; refusing to boot")
    domain, key = "com.apple.dt.Devices", "enableAudioOutput_tvOS"
    run(["defaults", "write", domain, key, "-bool", "false"])
    if command_text(["defaults", "read", domain, key]) != "0":
        raise VerificationError("Could not verify muted tvOS audio; refusing to boot")
    return {"domain": domain, "key": key, "enabled": False}


def execute_runtime(runtime, device_type, output, plan, required, baseline=None):
    output.mkdir()
    record = {"runtime": runtime, "plan": plan, "status": "failed", "output": str(output), "failures": []}
    device = None
    try:
        record["audio_output"] = mute_simulator_audio()
        device = command_text(["xcrun", "simctl", "create", "Bookworms tests " + output.parent.name,
                               device_type["identifier"], runtime["identifier"]])
        if not re.fullmatch(r"[0-9a-fA-F-]{36}", device):
            device = None
            raise VerificationError("simctl did not return a simulator UUID")
        record["simulator_id"] = device
        save_json(output / "owned-simulator.json", {"id": device})
        run(["xcrun", "simctl", "boot", device], capture_output=True, text=True)
        run(["xcrun", "simctl", "bootstatus", device, "-b"], capture_output=True, text=True)
        result = output / (plan + ".xcresult")
        command = ["xcodebuild", "-project", "Bookworms.xcodeproj", "-scheme", "Bookworms",
                   "-destination", "platform=tvOS Simulator,id=" + device,
                   "-derivedDataPath", str(output / "DerivedData"), "-testPlan", plan,
                   "-parallel-testing-enabled", "NO", "-jobs", "2", "-collect-test-diagnostics", "never",
                   "OTHER_SWIFT_FLAGS=$(inherited) -D BOOKWORMS_OFFLINE_TESTS",
                   "-resultBundlePath", str(result), "CODE_SIGNING_ALLOWED=NO", "test"]
        record["command"] = command
        print(f"Running {plan} on tvOS {runtime['version']}; log: {output / 'build.log'}", flush=True)
        with (output / "build.log").open("w") as log:
            completed = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=offline_environment())
        record["xcodebuild_exit_code"] = completed.returncode
        record.update(inspect_results(result, output, required, completed.returncode, baseline))
        record["status"] = "failed" if record["failures"] else "passed"
    except (subprocess.CalledProcessError, ValueError, OSError, VerificationError) as error:
        record["failures"].append(str(error))
    finally:
        if device:
            # Only this invocation's disposable simulator can be shut down or deleted.
            subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, env=offline_environment())
            deleted = subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True, text=True, env=offline_environment())
            record["simulator_deleted"] = deleted.returncode == 0
            if deleted.returncode:
                record["status"] = "failed"
                record["failures"].append("Disposable simulator cleanup failed: " + deleted.stderr.strip())
    save_json(output / "report.json", record)
    return record


def completion_failures(report):
    """A final pass requires every requested runtime and a verified source identity."""
    if not report.get("finished_at"):
        return []
    failures = []
    requested = report.get("requested_runtimes", [])
    completed = [record.get("requested_runtime") for record in report["runs"]]
    if not requested or sorted(completed, key=str) != sorted(requested):
        failures.append("Verification is incomplete: requested runtime results are missing or duplicated")
    if any(record.get("status") not in ("passed", "failed", "blocked") for record in report["runs"]):
        failures.append("Verification is incomplete: a runtime has no final outcome")
    before = report.get("source", {}).get("sha256")
    after = report.get("source_after", {}).get("sha256")
    if not before or not after:
        failures.append("Verification is incomplete: final source identity was not validated")
    elif before != after:
        failures.append("Source changed during verification; this run does not verify the final working tree")
    return failures


def report_status(report):
    # Persisted progress must never look like a finished pass if the process is killed.
    if not report.get("finished_at"):
        return "running"
    if completion_failures(report) or report.get("failures") or any(run["status"] == "failed" for run in report["runs"]):
        return "failed"
    if any(run["status"] == "blocked" for run in report["runs"]):
        return "blocked"
    return "passed"


def visual_review_status(report):
    requires_screenshots = report.get("plan") == "Local" or any(
        identifier.startswith("BookwormsUITests/") for identifier in report.get("required_tests", [])
    )
    if not requires_screenshots:
        return "not_applicable"
    if not report.get("finished_at"):
        return "pending"
    if completion_failures(report):
        return "blocked"
    for record in report["runs"]:
        evidence = record.get("visual_review", {})
        if (record["status"] == "blocked"
                or evidence.get("status") not in ("passed", "review_pending")
                or not any(image.get("path") for image in evidence.get("screenshots", []))):
            return "blocked"
    if any(record["visual_review"]["status"] == "review_pending" for record in report["runs"]):
        return "review_pending"
    return "passed"


def write_report(output, report):
    for failure in completion_failures(report):
        if failure not in report["failures"]:
            report["failures"].append(failure)
    report["status"] = report_status(report)
    report["visual_review_status"] = visual_review_status(report)
    save_json(output / "report.json", report)
    lines = ["# Local test verification", "", f"Automated verification: **{report['status']}**.",
             f"Visual review: **{report['visual_review_status']}**.", "",
             f"Source: `{report.get('source', {}).get('commit', 'unavailable')}`",
             f"Source SHA-256: `{report.get('source', {}).get('sha256', 'unavailable')}`", "",
             "Toolchain: " + report.get("toolchain", {}).get("xcode", "unavailable").replace("\n", "; ") + ".",
             "Developer directory: `" + report.get("toolchain", {}).get("developer_directory", "unavailable") + "`", "",
             "| Runtime | Build | Status | Passed / required | Coverage |", "| --- | --- | --- | --- | --- |"]
    artifacts = []
    for record in report["runs"]:
        runtime = record.get("runtime", {}).get("version", record.get("requested_runtime", "unknown"))
        passed = sum(test["result"] == "Passed" for test in record.get("tests", {}).values())
        coverage = record.get("coverage", {}).get("line_coverage")
        percentage = f"{coverage:.1%}" if isinstance(coverage, (int, float)) else "unavailable"
        build = record.get("runtime", {}).get("buildversion", "unavailable")
        lines.append(f"| {runtime} | {build} | {record['status']} | {passed} / {len(report.get('required_tests', []))} | {percentage} |")
        if record.get("output"):
            artifacts.append(f"- [{runtime} artifacts](<{record['output']}>)")
        visual = record.get("visual_review", {})
        if visual.get("report"):
            count = sum(bool(item.get("path")) for item in visual["screenshots"])
            artifacts.append(f"- [{runtime} screenshot review](<{visual['report']}>): {count} screenshots; {visual['status']}.")
    if artifacts:
        lines += ["", "## Artifacts", ""] + artifacts
    failures = report.get("failures", []) + [failure for run in report["runs"] for failure in run.get("failures", [])]
    if failures:
        lines += ["", "## Failed or blocked checks", ""] + ["- " + failure for failure in failures]
    lines += ["", "## Remaining verification", ""] + ["- " + check for check in REMAINING_CHECKS]
    if report["visual_review_status"] == "review_pending":
        lines.append("- Review exported screenshots and changed or missing approved baselines; nothing was automatically approved.")
    elif report["visual_review_status"] in ("pending", "blocked"):
        lines.append("- Visual verification is incomplete until every requested runtime has usable screenshot evidence and source validation completes.")
    lines += ["", "All tool output, test identifiers, runtime metadata, and commands are recorded in report.json and runtime artifact directories."]
    (output / "report.md").write_text("\n".join(lines) + "\n")


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", choices=["Local", "Unit"], default="Local")
    parser.add_argument("--runtime", action="append", help="Exact tvOS version or runtime identifier; repeat for multiple runtimes")
    parser.add_argument("--major", action="store_true", help="Run Local on every required runtime in TestPlans/runtime-matrix.json")
    parser.add_argument("--output", type=Path, help="New artifact directory outside source control; must not already exist")
    parser.add_argument("--baseline-dir", type=Path, help="Read-only approved screenshots, organized as tvOS-VERSION/*.png")
    args = parser.parse_args(argv)
    if args.major and (args.plan != "Local" or args.runtime):
        parser.error("--major requires the Local plan and configured matrix; omit --plan Unit and --runtime")
    if args.runtime and len(args.runtime) != len(set(args.runtime)):
        parser.error("--runtime values must be unique")
    return args


def main(argv=None):
    args = parse_arguments(argv)
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S")
    output = args.output.resolve() if args.output else ROOT / ".local" / "test-results" / (timestamp + "-" + uuid.uuid4().hex[:8])
    output.mkdir(parents=True, exist_ok=False)
    report = {"schema_version": 1, "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "plan": args.plan, "major": args.major, "runs": [], "failures": [], "remaining_checks": REMAINING_CHECKS}
    write_report(output, report)
    try:
        report["source"] = source_identity()
        report["toolchain"] = {"xcode": command_text(["xcodebuild", "-version"]),
                               "developer_directory": command_text(["xcode-select", "-p"]),
                               "python": sys.version}
        required = discover_required_tests(ROOT, args.plan)
        report["required_tests"] = required
        inventory = command_json(["xcrun", "simctl", "list", "--json"], output / "simulators.json")
        requested = args.runtime
        if args.major:
            matrix = json.loads((ROOT / "TestPlans" / "runtime-matrix.json").read_text())
            requested = matrix["required_runtimes"]
            if not requested or len(requested) != len(set(requested)):
                raise VerificationError("Runtime matrix must contain unique required runtimes")
            report["runtime_matrix"] = matrix
        device_type = next((d for d in inventory["devicetypes"] if "Apple-TV-4K-3rd-generation" in d["identifier"]), None)
        selected_runtimes = select_runtimes(inventory, requested)
        report["requested_runtimes"] = [version for version, _ in selected_runtimes]
        write_report(output, report)
        for requested_runtime, runtime in selected_runtimes:
            if not runtime or not device_type:
                reason = f"Required tvOS runtime {requested_runtime} or Apple TV 4K simulator device type is not installed. Install it in Xcode Settings → Components."
                report["runs"].append({"requested_runtime": requested_runtime, "status": "blocked", "failures": [reason]})
                write_report(output, report)
                continue
            runtime_output = output / ("tvOS-" + runtime["version"])
            baseline = args.baseline_dir.resolve() / runtime_output.name if args.baseline_dir else None
            record = execute_runtime(runtime, device_type, runtime_output, args.plan, required, baseline)
            record["requested_runtime"] = requested_runtime
            report["runs"].append(record)
            write_report(output, report)
        report["source_after"] = source_identity()
    except (subprocess.CalledProcessError, ValueError, OSError, VerificationError, KeyError) as error:
        report["failures"].append(str(error))
    except KeyboardInterrupt:
        report["failures"].append("Verification was interrupted")
    report["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    write_report(output, report)
    print(f"Automated verification: {report['status']}; visual review: {report['visual_review_status']}", flush=True)
    print("Report:", output / "report.md", flush=True)
    return {"passed": 0, "failed": 1, "blocked": 2}[report["status"]]


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    sys.exit(main())
