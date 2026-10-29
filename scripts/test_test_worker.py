import copy
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("worker", Path(__file__).with_name("test-worker.py"))
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
GUARD = "BookwormsTests/OfflinePolicyTests/testWorkerBuildRejectsUnexpectedNetworkAndCredentials"
UI_GUARD = "BookwormsUITests/OfflinePolicyUITests/testOfflineGuardSurvivesAppRelaunch"


def report():
    return {"finished_at": "done", "status": "passed", "source": {"sha256": "same"},
        "source_after": {"sha256": "same"}, "requested_runtimes": ["27.0"],
        "required_tests": [GUARD], "failures": [], "visual_review_status": "review_pending",
        "runs": [{"status": "passed", "requested_runtime": "27.0", "simulator_id": "test",
                  "simulator_deleted": True, "tests": {GUARD: {"result": "Passed"}}, "failures": []}]}


def local_report():
    """A Local run: the full pass, then a Reduce Motion pass with its own required tests."""
    d = report()
    d["required_tests"] = [GUARD, UI_GUARD, "BookwormsTests/OtherTests/testOther"]
    d["requested_runtimes"] = ["27.0", "27.0 with Reduce Motion"]
    d["runs"][0]["tests"] = {test: {"result": "Passed"} for test in d["required_tests"]}
    reduced = copy.deepcopy(d["runs"][0])
    reduced["requested_runtime"] = "27.0 with Reduce Motion"
    reduced["required_tests"] = [GUARD, UI_GUARD]
    reduced["tests"] = {test: {"result": "Passed"} for test in reduced["required_tests"]}
    d["runs"].append(reduced)
    return d


class WorkerTests(unittest.TestCase):
    def handoff(self, value=None, code=0, problem=None, profile="unit"):
        return w.make_handoff(report() if value is None else value, profile, code, Path("/tmp/run"), problem)

    def test_clean_pass_and_bounded_markdown(self):
        h = self.handoff()
        self.assertEqual(h["status"], "passed")
        with tempfile.TemporaryDirectory() as folder:
            h["failures"] = ["large " * 500] * 30
            w.write_handoff(Path(folder), h)
            self.assertLessEqual(len((Path(folder) / "handoff.md").read_text().split()), 600)

    def test_no_false_green(self):
        cases = []
        d = report(); d["source_after"]["sha256"] = "changed"; cases.append(d)
        d = report(); d["runs"][0]["tests"] = {}; cases.append(d)
        d = report(); d["runs"][0]["tests"][GUARD]["result"] = "Skipped"; cases.append(d)
        d = report(); d["runs"][0]["simulator_deleted"] = False; cases.append(d)
        d = report(); d.pop("finished_at"); cases.append(d)
        d = report(); d["requested_runtimes"].append("26.0"); cases.append(d)
        d = report(); d["runs"][0]["tests"]["invented"] = {"result": "Passed"}; cases.append(d)
        for d in cases:
            with self.subTest(report=d):
                self.assertNotEqual(self.handoff(d)["status"], "passed")

    def test_local_profile_requires_ui_guard_and_per_run_tests(self):
        self.assertEqual(self.handoff(local_report(), profile="local")["status"], "passed")
        cases = []
        # The Reduce Motion pass lists every test it ran but lacks the UI guard.
        d = local_report(); d["runs"][1]["required_tests"] = [GUARD]; d["runs"][1]["tests"] = {GUARD: {"result": "Passed"}}; cases.append(d)
        d = local_report(); d["runs"][1]["tests"]["BookwormsTests/OtherTests/testOther"] = {"result": "Passed"}; cases.append(d)
        for d in cases:
            with self.subTest(report=d):
                self.assertNotEqual(self.handoff(d, profile="local")["status"], "passed")

    def test_malformed_and_missing_reports(self):
        for value in [[], {}, {"runs": [None]}, {"runs": [{"tests": []}]}]:
            self.assertEqual(self.handoff(value, 2)["status"], "blocked")
        # A finished report from a runner that exited 0 is still rejected for its shape.
        for run in [None, {"tests": []}, {"tests": {}, "summary": []}, {"tests": {}, "failures": "text"}]:
            with self.subTest(run=run):
                handoff = self.handoff(dict(report(), runs=[run]), 0)
                self.assertNotEqual(handoff["status"], "passed")
                self.assertIn("Malformed runner report", handoff["failures"])

    def test_worker_deleted_simulator_is_not_reported_as_leaked(self):
        d = report(); d["runs"][0]["simulator_deleted"] = False
        self.assertIn("Owned simulator cleanup is incomplete", self.handoff(d)["failures"])
        handoff = w.make_handoff(d, "unit", 0, Path("/tmp/run"), removed=["test"])
        self.assertNotIn("Owned simulator cleanup is incomplete", handoff["failures"])
        self.assertTrue(handoff["runs"][0]["simulator_deleted"])

    def test_blocked_runtime(self):
        d = report(); d["status"] = "blocked"; d["runs"][0]["status"] = "blocked"
        self.assertEqual(self.handoff(d, 2)["status"], "blocked")

    def test_rejects_unapproved_cli(self):
        for args in [["--profile", "Device"], ["--device", "TV"], ["--command", "curl"], ["--endpoint", "https://example.com"]]:
            with self.assertRaises(SystemExit) as error:
                w.main(args)
            self.assertEqual(error.exception.code, 2)

    def test_timeout_does_not_retry(self):
        with tempfile.TemporaryDirectory() as folder:
            code, reason = w.execute([sys.executable, "-c", "import time; time.sleep(10)"], Path(folder) / "log", timeout=0.1)
            self.assertEqual(code, 2)
            self.assertIn("no retry", reason)

    def test_model_cannot_change_status_or_citations(self):
        valid = {"status": "failed", "groups": [{"hypothesis": "Possible mismatch", "evidence": ["F0"], "tests": ["known"]}]}
        w.validate_analysis(valid, "failed", {"F0"}, {"known"})
        for key, value in [("status", "passed"), ("groups", [{"hypothesis": "bad", "evidence": ["unknown"], "tests": []}])]:
            invalid = copy.deepcopy(valid); invalid[key] = value
            with self.assertRaises(ValueError):
                w.validate_analysis(invalid, "failed", {"F0"}, {"known"})

    def test_model_unavailable_and_redirects(self):
        with patch.object(w, "local_request", side_effect=OSError("unavailable")):
            with self.assertRaises(OSError):
                w.summarize(self.handoff())
        with self.assertRaises(ValueError):
            w.NoRedirect().redirect_request(None)
        with self.assertRaises(ValueError):
            w.local_request("https://example.com")
        # The opener replaces the default redirect handler and ignores proxy settings.
        handlers = []

        def build_opener(*arguments):
            handlers.extend(arguments)
            raise OSError("stop before connecting")

        with patch.object(w.urllib.request, "build_opener", side_effect=build_opener):
            with self.assertRaises(OSError):
                w.local_request("/api/v1/models")
        self.assertTrue(any(isinstance(h, w.NoRedirect) for h in handlers))
        proxies = [h for h in handlers if isinstance(h, w.urllib.request.ProxyHandler)]
        self.assertEqual([h.proxies for h in proxies], [{}])

    def test_summary_schema_allows_only_supplied_test_identifiers(self):
        failed = report(); failed["runs"][0]["tests"][GUARD]["result"] = "Failed"
        handoff = self.handoff(failed)
        requests = []

        def respond(path, body=None, timeout=120):
            if path == "/api/v1/models":
                return {"models": [{"loaded_instances": [{"id": w.MODEL, "config": {"context_length": 8192, "parallel": 1}}]}]}
            requests.append(body)
            return {"choices": [{"finish_reason": "length", "message": {"content": ""}}]}

        with patch.object(w, "local_request", side_effect=respond), self.assertRaises(ValueError):
            w.summarize(handoff)
        schema = requests[0]["response_format"]["json_schema"]["schema"]
        tests = schema["properties"]["groups"]["items"]["properties"]["tests"]
        self.assertEqual(tests["items"]["enum"], [GUARD])

    def test_environment_scrub(self):
        with patch.dict(os.environ, {"TEST_RUNNER_VERIFY_DEVICE_SOCIAL": "1", "SIMCTL_CHILD_HARDCOVER_BOOTSTRAP_TOKEN": "secret", "OPENAI_API_KEY": "secret"}):
            env = w.runner.offline_environment()
            self.assertNotIn("TEST_RUNNER_VERIFY_DEVICE_SOCIAL", env)
            self.assertNotIn("OPENAI_API_KEY", env)
            self.assertNotIn("SIMCTL_CHILD_HARDCOVER_BOOTSTRAP_TOKEN", env)

    def test_concurrent_worker_is_blocked(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(w, "ROOT", Path(folder)):
            base = Path(folder) / ".local/test-worker"; base.mkdir(parents=True)
            with (base / "worker.lock").open("a") as lock, patch.object(w.subprocess, "Popen") as spawn:
                w.fcntl.flock(lock, w.fcntl.LOCK_EX | w.fcntl.LOCK_NB)
                self.assertEqual(w.main([]), 2)
                self.assertEqual(w.main(["--detach"]), 2)
                spawn.assert_not_called()

    def test_mute_preflight_writes_only_device_hub_preference(self):
        with patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_bytes", return_value=b"enableAudioOutput_tvOS"), patch.object(w.runner, "command_text", side_effect=["/Applications/Xcode.app/Contents/Developer", "0"]), patch.object(w.runner, "run") as run:
            self.assertFalse(w.runner.mute_simulator_audio()["enabled"])
            run.assert_called_once_with(["defaults", "write", "com.apple.dt.Devices", "enableAudioOutput_tvOS", "-bool", "false"])

    def test_unverified_mute_blocks_boot(self):
        with patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_bytes", return_value=b"enableAudioOutput_tvOS"), patch.object(w.runner, "command_text", side_effect=["/Applications/Xcode.app/Contents/Developer", "1"]), patch.object(w.runner, "run"):
            with self.assertRaises(w.runner.VerificationError):
                w.runner.mute_simulator_audio()

    def test_current_network_boundaries_are_guarded(self):
        w.preflight()


if __name__ == "__main__":
    unittest.main()
