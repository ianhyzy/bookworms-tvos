#!/usr/bin/env python3
"""Fault-injection tests for test-local.py; no Xcode or simulator is required."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("test_local", Path(__file__).with_name("test-local.py"))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


def result_tree(status="Passed", method="testExample"):
    return {"testNodes": [{"nodeType": "Unit test bundle", "name": "BookwormsTests", "children": [
        {"nodeType": "Test Suite", "name": "ExampleTests", "children": [
            {"nodeType": "Test Case", "name": method + "()", "nodeIdentifier": "ExampleTests/" + method + "()",
             "result": status, "durationInSeconds": 0.001}]}]}]}


def result_summary(**overrides):
    value = {"result": "Passed", "totalTestCount": 1, "passedTests": 1, "failedTests": 0,
             "skippedTests": 0, "expectedFailures": 0}
    value.update(overrides)
    return value


REQUIRED = ["BookwormsTests/ExampleTests/testExample"]


class ResultValidationTests(unittest.TestCase):
    def test_pass_requires_actual_required_case(self):
        outcomes, failures = runner.validate_results(result_summary(), result_tree(), REQUIRED, 0)
        self.assertEqual(failures, [])
        self.assertEqual(set(outcomes), set(REQUIRED))

    def test_zero_exit_does_not_hide_failed_test(self):
        _, failures = runner.validate_results(result_summary(), result_tree("Failed"), REQUIRED, 0)
        self.assertTrue(any("testExample: Failed" in item for item in failures))

    def test_process_failure_does_not_become_pass_with_good_result(self):
        _, failures = runner.validate_results(result_summary(), result_tree(), REQUIRED, 65)
        self.assertIn("xcodebuild exited with status 65", failures)

    def test_skip_is_failure(self):
        _, failures = runner.validate_results(result_summary(skippedTests=1, passedTests=0),
                                             result_tree("Skipped"), REQUIRED, 0)
        self.assertTrue(any("Skipped" in item for item in failures))

    def test_missing_required_test_is_failure_even_with_equal_count(self):
        _, failures = runner.validate_results(result_summary(), result_tree(method="testDifferent"), REQUIRED, 0)
        self.assertTrue(any("Required tests did not run" in item for item in failures))
        self.assertTrue(any("absent from source/plan" in item for item in failures))

    def test_empty_result_is_failure(self):
        _, failures = runner.validate_results(result_summary(totalTestCount=0, passedTests=0), {"testNodes": []}, REQUIRED, 0)
        self.assertIn("Result contains no test cases", failures)

    def test_malformed_enumeration_is_failure(self):
        with self.assertRaises(runner.VerificationError):
            runner.test_outcomes({})

    def test_duplicate_results_are_rejected(self):
        tree = result_tree()
        tree["testNodes"].append(tree["testNodes"][0])
        with self.assertRaisesRegex(runner.VerificationError, "Duplicate"):
            runner.test_outcomes(tree)

    def test_inconsistent_summary_is_failure(self):
        _, failures = runner.validate_results(result_summary(totalTestCount=3), result_tree(), REQUIRED, 0)
        self.assertIn("Summary test count does not match enumerated results", failures)

    def test_missing_bundle_never_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(runner.VerificationError, "did not create"):
                runner.inspect_results(root / "missing.xcresult", root, REQUIRED, 0)

    def test_coverage_export_process_failure_is_not_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = root / "Local.xcresult"
            result.mkdir()
            failure = subprocess.CalledProcessError(1, ["xccov"])
            with mock.patch.object(runner, "command_json", side_effect=[result_summary(), result_tree(), failure]), \
                 mock.patch.object(runner, "run"), \
                 mock.patch.object(runner, "compare_screenshots", return_value={"status": "not_applicable", "screenshots": []}):
                evidence = runner.inspect_results(result, root, REQUIRED, 0)
            self.assertTrue(any("Coverage export failed" in item for item in evidence["failures"]))

    def test_empty_or_test_only_coverage_is_rejected(self):
        for coverage in ({}, {"targets": []}, {"targets": [{"name": "BookwormsTests.xctest", "executableLines": 10}]}):
            with self.subTest(coverage=coverage), self.assertRaises(runner.VerificationError):
                runner.validate_coverage(coverage)

    def test_valid_app_coverage_is_retained(self):
        value = runner.validate_coverage({"targets": [{"name": "Bookworms.app", "executableLines": 10,
                                                        "coveredLines": 7, "lineCoverage": .7}]})
        self.assertEqual(value["line_coverage"], .7)

    def test_missing_or_inconsistent_app_coverage_is_rejected(self):
        for fields in ({}, {"coveredLines": 7}, {"coveredLines": 11, "lineCoverage": 1.1},
                       {"coveredLines": 7, "lineCoverage": .8}, {"coveredLines": 7, "lineCoverage": float("nan")}):
            with self.subTest(fields=fields), self.assertRaises(runner.VerificationError):
                runner.validate_coverage({"targets": [{"name": "Bookworms.app", "executableLines": 10, **fields}]})


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "TestPlans").mkdir()
        (self.root / "BookwormsTests").mkdir()
        (self.root / "BookwormsTests" / "ExampleTests.swift").write_text('''
import XCTest
final class ExampleTests: XCTestCase {
  // func testComment() {}
  func testExample() { let text = "func testString() {}" }
  func testSecond() async throws { let body = { return "}" }; _ = body() }
}
final class DeviceTests: XCTestCase { func testDeviceOnly() {} }
''')
        self.plan = {"testTargets": [{"target": {"name": "BookwormsTests"}, "selectedTests": ["ExampleTests"]}]}

    def discover(self):
        (self.root / "TestPlans" / "Local.xctestplan").write_text(json.dumps(self.plan))
        return runner.discover_required_tests(self.root, "Local")

    def test_only_plan_selected_classes_and_real_methods_are_required(self):
        self.assertEqual(self.discover(), REQUIRED + ["BookwormsTests/ExampleTests/testSecond"])

    def test_new_source_test_is_automatically_required(self):
        path = self.root / "BookwormsTests" / "ExampleTests.swift"
        path.write_text(path.read_text().replace("func testSecond", "func testNew() {}\n  func testSecond"))
        self.assertIn("BookwormsTests/ExampleTests/testNew", self.discover())

    def test_method_selection_and_plan_exclusion(self):
        self.plan["testTargets"][0]["skippedTests"] = ["ExampleTests/testSecond()"]
        self.assertEqual(self.discover(), REQUIRED)
        self.plan["testTargets"][0]["selectedTests"] = ["ExampleTests/testExample()"]
        self.assertEqual(self.discover(), REQUIRED)

    def test_stale_plan_selection_is_failure(self):
        self.plan["testTargets"][0]["selectedTests"] = ["RenamedTests"]
        with self.assertRaisesRegex(runner.VerificationError, "undiscovered"):
            self.discover()


class VisualEvidenceTests(unittest.TestCase):
    def test_missing_and_changed_baselines_remain_pending_and_are_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            attachments = root / "attachments"
            attachments.mkdir()
            (attachments / "example.png").write_bytes(b"fake image bytes")
            manifest = [{"testIdentifier": "VisualTests/testShelf()", "attachments": [{
                "exportedFileName": "example.png",
                "suggestedHumanReadableName": "Shelf light_0_12345678-1234-1234-1234-123456789ABC.png"}]}]
            (attachments / "manifest.json").write_text(json.dumps(manifest))
            baseline = root / "baseline"
            baseline.mkdir()
            for index, expected in enumerate(("missing_baseline", "changed", "unchanged")):
                output = root / str(index)
                output.mkdir()
                evidence = runner.compare_screenshots(attachments, output, baseline)
                record = evidence["screenshots"][0]
                self.assertEqual(record["comparison"], expected)
                self.assertEqual(evidence["status"], "passed" if expected == "unchanged" else "review_pending")
                approved = baseline / record["name"]
                if index == 0:
                    self.assertFalse(approved.exists())
                    approved.write_bytes(b"original approved")
                elif index == 1:
                    self.assertEqual(approved.read_bytes(), b"original approved")
                    approved.write_bytes(b"fake image bytes")
                self.assertTrue((output / "visual-review.html").is_file())

    def test_previously_approved_screen_missing_from_run_stays_pending(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            attachments = root / "attachments"
            attachments.mkdir()
            (attachments / "manifest.json").write_text("[]")
            baseline = root / "baseline"
            baseline.mkdir()
            (baseline / "previous-screen.png").write_bytes(b"approved")
            evidence = runner.compare_screenshots(attachments, root, baseline)
            self.assertEqual(evidence["status"], "review_pending")
            self.assertEqual(evidence["screenshots"][0]["comparison"], "missing_current")

    def test_missing_attachment_manifest_is_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(runner.VerificationError):
                runner.compare_screenshots(Path(directory), Path(directory), None)


class ReportStateTests(unittest.TestCase):
    def complete_report(self):
        return {
            "plan": "Local", "finished_at": "2026-09-17T12:00:00+00:00",
            "requested_runtimes": ["26.0", "27.0"],
            "source": {"sha256": "same"}, "source_after": {"sha256": "same"}, "failures": [],
            "runs": [{"requested_runtime": version, "status": "passed", "visual_review": {
                "status": "passed", "screenshots": [{"path": "approved-screen.png"}]
            }} for version in ("26.0", "27.0")],
        }

    def test_progress_cannot_pass_before_finalization(self):
        report = self.complete_report()
        del report["finished_at"]
        for count in (0, 1, 2):
            with self.subTest(completed=count):
                progress = dict(report, runs=report["runs"][:count])
                self.assertEqual(runner.report_status(progress), "running")
                self.assertEqual(runner.visual_review_status(progress), "pending")

    def test_final_report_requires_all_requested_runtime_results(self):
        for change in ("missing", "duplicate", "unfinished"):
            with self.subTest(change=change):
                report = self.complete_report()
                if change == "missing":
                    report["runs"].pop()
                elif change == "duplicate":
                    report["runs"][1] = report["runs"][0]
                else:
                    report["runs"][1]["status"] = "running"
                self.assertEqual(runner.report_status(report), "failed")
                self.assertEqual(runner.visual_review_status(report), "blocked")

    def test_final_report_requires_source_revalidation(self):
        for after in (None, {}, {"sha256": "changed"}):
            with self.subTest(after=after):
                report = self.complete_report()
                if after is None:
                    del report["source_after"]
                else:
                    report["source_after"] = after
                self.assertEqual(runner.report_status(report), "failed")
                self.assertEqual(runner.visual_review_status(report), "blocked")

    def test_completed_matching_matrix_can_pass(self):
        report = self.complete_report()
        self.assertEqual(runner.report_status(report), "passed")
        self.assertEqual(runner.visual_review_status(report), "passed")

    def test_one_runtime_cannot_hide_missing_visual_evidence(self):
        for change in ("blocked", "export_failed", "empty", "not_applicable"):
            with self.subTest(change=change):
                report = self.complete_report()
                record = report["runs"][1]
                if change in ("blocked", "export_failed"):
                    record["status"] = "blocked" if change == "blocked" else "failed"
                    del record["visual_review"]
                elif change == "empty":
                    record["visual_review"]["screenshots"] = []
                else:
                    record["visual_review"]["status"] = "not_applicable"
                self.assertEqual(runner.visual_review_status(report), "blocked")

    def test_missing_baseline_remains_review_pending_after_complete_matrix(self):
        report = self.complete_report()
        report["runs"][1]["visual_review"]["status"] = "review_pending"
        self.assertEqual(runner.report_status(report), "passed")
        self.assertEqual(runner.visual_review_status(report), "review_pending")

    def test_unit_report_does_not_require_screenshots(self):
        report = self.complete_report()
        report["plan"] = "Unit"
        for record in report["runs"]:
            del record["visual_review"]
        self.assertEqual(runner.report_status(report), "passed")
        self.assertEqual(runner.visual_review_status(report), "not_applicable")

    def test_incomplete_final_report_explains_failure_in_both_formats(self):
        with tempfile.TemporaryDirectory() as directory:
            report = self.complete_report()
            del report["source_after"]
            runner.write_report(Path(directory), report)
            saved = json.loads((Path(directory) / "report.json").read_text())
            self.assertEqual(saved["status"], "failed")
            self.assertEqual(saved["visual_review_status"], "blocked")
            self.assertIn("final source identity was not validated", saved["failures"][0])
            self.assertIn("final source identity was not validated", (Path(directory) / "report.md").read_text())


class ExecutionTests(unittest.TestCase):
    def test_unavailable_requested_runtime_does_not_fall_back(self):
        inventory = {"runtimes": [{"isAvailable": True, "version": "27.0", "identifier": "com.apple.tvOS-27-0"}]}
        selected = runner.select_runtimes(inventory, ["26.0", "27.0"])
        self.assertIsNone(selected[0][1])
        self.assertEqual(selected[1][1]["version"], "27.0")

    def test_missing_runtime_produces_blocked_report(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "results"
            source = {"sha256": "unchanged", "commit": "abc"}
            with mock.patch.object(runner, "source_identity", return_value=source), \
                 mock.patch.object(runner, "command_text", return_value="Xcode test"), \
                 mock.patch.object(runner, "discover_required_tests", return_value=REQUIRED), \
                 mock.patch.object(runner, "command_json", return_value={"runtimes": [], "devicetypes": []}):
                code = runner.main(["--runtime", "26.0", "--output", str(output)])
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(code, 2)
            self.assertEqual(report["status"], "blocked")

    def test_source_mutation_invalidates_results(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "results"
            with mock.patch.object(runner, "source_identity", side_effect=[{"sha256": "before"}, {"sha256": "after"}]), \
                 mock.patch.object(runner, "command_text", return_value="Xcode test"), \
                 mock.patch.object(runner, "discover_required_tests", return_value=REQUIRED), \
                 mock.patch.object(runner, "command_json", return_value={"runtimes": [], "devicetypes": []}):
                code = runner.main(["--runtime", "26.0", "--output", str(output)])
            self.assertEqual(code, 1)
            self.assertIn("Source changed", (output / "report.md").read_text())

    def test_matrix_progress_stays_running_until_final_source_check(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "results"
            source_checks = 0

            def source_identity():
                nonlocal source_checks
                source_checks += 1
                saved = json.loads((output / "report.json").read_text())
                self.assertEqual(saved["status"], "running")
                self.assertEqual(len(saved["runs"]), 0 if source_checks == 1 else 2)
                return {"sha256": "unchanged", "commit": "abc"}

            def execute(runtime, *arguments):
                saved = json.loads((output / "report.json").read_text())
                self.assertEqual(saved["status"], "running")
                self.assertEqual(saved["requested_runtimes"], ["26.0", "27.0"])
                return {"status": "passed", "runtime": runtime, "failures": []}

            inventory = {"runtimes": [
                {"isAvailable": True, "version": version, "identifier": "com.apple.tvOS-" + version}
                for version in ("26.0", "27.0")
            ], "devicetypes": [{"identifier": "Apple-TV-4K-3rd-generation"}]}
            with mock.patch.object(runner, "source_identity", side_effect=source_identity), \
                 mock.patch.object(runner, "command_text", return_value="Xcode test"), \
                 mock.patch.object(runner, "discover_required_tests", return_value=REQUIRED), \
                 mock.patch.object(runner, "command_json", return_value=inventory), \
                 mock.patch.object(runner, "execute_runtime", side_effect=execute):
                code = runner.main(["--plan", "Unit", "--runtime", "26.0", "--runtime", "27.0", "--output", str(output)])
            self.assertEqual(code, 0)
            saved = json.loads((output / "report.json").read_text())
            self.assertEqual(saved["status"], "passed")
            self.assertIn("finished_at", saved)

    def test_build_failure_still_deletes_only_created_simulator(self):
        device = "12345678-1234-1234-1234-123456789ABC"
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "tvOS-27.0"
            completed = subprocess.CompletedProcess([], 65, stderr="")
            deleted = subprocess.CompletedProcess([], 0, stderr="")
            with mock.patch.object(runner, "mute_simulator_audio", return_value={"enabled": False}), \
                 mock.patch.object(runner, "command_text", return_value=device), \
                 mock.patch.object(runner, "run"), \
                 mock.patch.object(runner.subprocess, "run", side_effect=[completed, deleted, deleted]) as process:
                record = runner.execute_runtime({"version": "27.0", "identifier": "runtime"},
                                                {"identifier": "tv"}, output, "Unit", REQUIRED)
            self.assertEqual(record["status"], "failed")
            self.assertTrue(record["simulator_deleted"])
            self.assertEqual(process.call_args_list[-1].args[0], ["xcrun", "simctl", "delete", device])
            build_command = process.call_args_list[0].args[0]
            self.assertIn(str(output / "DerivedData"), build_command)

    def test_failed_simulator_cleanup_invalidates_success(self):
        device = "12345678-1234-1234-1234-123456789ABC"
        success = subprocess.CompletedProcess([], 0, stderr="")
        denied = subprocess.CompletedProcess([], 1, stderr="device unavailable")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "tvOS-27.0"
            with mock.patch.object(runner, "mute_simulator_audio", return_value={"enabled": False}), \
                 mock.patch.object(runner, "command_text", return_value=device), \
                 mock.patch.object(runner, "run"), \
                 mock.patch.object(runner, "inspect_results", return_value={"failures": []}), \
                 mock.patch.object(runner.subprocess, "run", side_effect=[success, success, denied]):
                record = runner.execute_runtime({"version": "27.0", "identifier": "runtime"},
                                                {"identifier": "tv"}, output, "Unit", REQUIRED)
            self.assertEqual(record["status"], "failed")
            self.assertFalse(record["simulator_deleted"])
            self.assertIn("cleanup failed", record["failures"][0])

    def test_offline_processes_never_inherit_bootstrap_credentials(self):
        variables = {"PATH": "/bin", "HARDCOVER_BOOTSTRAP_TOKEN": "secret",
                     "SIMCTL_CHILD_CWA_BOOTSTRAP_PASSWORD": "secret", "TEST_RUNNER_GEMINI_BOOTSTRAP_TOKEN": "secret",
                     "TEST_RUNNER_VERIFY_LIVE_SERVICES": "1", "VERIFY_LIVE_SERVICES": "1"}
        with mock.patch.dict(os.environ, variables, clear=True):
            self.assertEqual(runner.offline_environment(), {"PATH": "/bin"})

    def test_major_cannot_silently_be_narrowed_to_unit_or_one_runtime(self):
        with self.assertRaises(SystemExit):
            runner.parse_arguments(["--major", "--plan", "Unit"])
        with self.assertRaises(SystemExit):
            runner.parse_arguments(["--major", "--runtime", "27.0"])


if __name__ == "__main__":
    unittest.main()
