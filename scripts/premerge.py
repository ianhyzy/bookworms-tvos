#!/usr/bin/env python3
"""Checks the head commit before its pull request merges, and records a pass for it.

Steps, each printed as one PASS, FAIL, or SKIP line, with full output in the log file:

  tree   the working tree has no uncommitted or untracked files, so the pass names one commit
  lint   `swift-format lint --strict` on the Swift files changed against the base
  build  a Release build for the Apple TV simulator (the BookwormsDevice scheme)
  test   the Unit plan through scripts/test-local.py, which creates one slim simulator and
         deletes it
  links  relative links in the changed Markdown files

A change that touches only documentation (Markdown files, docs/, and LICENSE) skips lint,
build, and test. When every step passes, the script writes `premerge/<commit>.json` in the
repository's shared Git folder, which all worktrees use. The workspace's merge gate refuses
`gh pr merge` for a head commit without that file. The file also lists the views the change
touches (scripts/visual-check.py --list); a commit that touches any needs a visual check too.

Run it with the Bash sandbox off, because xcodebuild can't reach the Metal toolchain inside it.
Exit codes: 0 pass, 1 fail.
"""
import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = Path(__file__).resolve().parent.relative_to(ROOT)
DOCUMENTATION = re.compile(r"(^|/)[^/]+\.md$|^docs/|^LICENSE")
LINK = re.compile(r"\]\(([^)#\s]+)(?:#[^)\s]*)?\)")


def git(*arguments):
    return subprocess.run(["git", *arguments], cwd=ROOT, capture_output=True, text=True).stdout.strip()


class Run:
    """One pre-merge run: its log, its steps' results, and the line printed for each step."""

    def __init__(self, sha):
        self.sha = sha
        self.folder = ROOT / ".local" / "premerge" / sha[:9]
        # Earlier runs' logs and results go; the build folder stays for incremental builds.
        for earlier in self.folder.parent.glob("*"):
            if not earlier.name.startswith("DerivedData"):
                shutil.rmtree(earlier, ignore_errors=True)
        self.folder.mkdir(parents=True)
        self.log = self.folder / "premerge.log"
        self.results = {}

    def command(self, arguments):
        """Runs a command with its output appended to the log, and returns its exit code."""
        with self.log.open("a") as log:
            log.write(f"\n$ {' '.join(map(str, arguments))}\n")
            log.flush()
            return subprocess.run(arguments, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT).returncode

    def report(self, step, result, detail):
        self.results[step] = result
        print(f"{result:<4} {step:<14} {detail}", flush=True)

    def check(self, step, passed, detail):
        self.report(step, "PASS" if passed else "FAIL", detail)

    @property
    def failed(self):
        return [step for step, result in self.results.items() if result == "FAIL"]


def simulator_limit():
    """Returns why one more simulator would break the workspace's simulator limits, or None.

    Checks the count and free memory once; it doesn't watch whether swap use is climbing.
    """
    booted = subprocess.run(["xcrun", "simctl", "list", "devices", "booted"],
                            capture_output=True, text=True).stdout.count("(Booted)")
    if booted >= 10:
        return f"{booted} simulators are already booted"
    pressure = subprocess.run(["memory_pressure", "-Q"], capture_output=True, text=True).stdout
    free = re.search(r"free percentage: (\d+)%", pressure)
    if free and int(free.group(1)) < 15:
        return f"only {free.group(1)}% of memory is free"
    return None


def broken_links(files):
    """Returns `file: target` for each relative Markdown link whose target doesn't exist."""
    broken = []
    for name in files:
        for target in LINK.findall((ROOT / name).read_text()):
            if not re.match(r"[a-z][a-z0-9+.-]*:", target) and not (ROOT / name).parent.joinpath(target).exists():
                broken.append(f"{name}: {target}")
    return broken


def build(run):
    run.check("build Apple TV", run.command([
        "xcodebuild", "-quiet", "-project", "Bookworms.xcodeproj", "-scheme", "BookwormsDevice",
        "-configuration", "Release", "-destination", "generic/platform=tvOS Simulator",
        "-derivedDataPath", str(run.folder.parent / "DerivedData"), "CODE_SIGNING_ALLOWED=NO",
        "build"]) == 0, "simulator, Release")


def test(run):
    limit = simulator_limit()
    if limit:
        return run.check("test", False, f"no simulator started: {limit}")
    output = run.folder / "unit"
    code = run.command([sys.executable, str(SCRIPTS / "test-local.py"), "--plan", "Unit",
                        "--output", str(output)])
    shutil.rmtree(output / "DerivedData", ignore_errors=True)
    for simulator in output.glob("*/DerivedData"):
        shutil.rmtree(simulator, ignore_errors=True)
    try:
        report = json.loads((output / "report.json").read_text())
        count = len(report.get("required_tests", []))
    except (OSError, ValueError):
        count = 0
    run.check("test", code == 0, f"Unit plan, {count} tests on one slim simulator; report {output / 'report.md'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--base", default="origin/main",
                        help="branch the pull request merges into (default: origin/main)")
    arguments = parser.parse_args()

    sha = git("rev-parse", "HEAD")
    run = Run(sha)
    print(f"premerge {sha[:9]} ({git('rev-parse', '--abbrev-ref', 'HEAD')}); log {run.log}", flush=True)
    dirty = git("status", "--porcelain")
    run.check("tree", not dirty, "clean" if not dirty else "commit or remove: "
              + ", ".join(line[3:] for line in dirty.splitlines()[:5]))
    if arguments.base.startswith("origin/"):
        run.command(["git", "fetch", "--quiet", "origin", arguments.base.split("/", 1)[1]])
    base = git("merge-base", arguments.base, "HEAD")
    if not base:
        run.check("base", False, f"no merge base with {arguments.base}")
    changed = [name for name in git("diff", "--name-only", "--diff-filter=d", base, "HEAD").splitlines()
               if name]
    code_changed = [name for name in changed if not DOCUMENTATION.search(name)]

    if run.failed:
        pass
    elif not code_changed:
        for step in ("lint", "build Apple TV", "test"):
            run.report(step, "SKIP", "documentation only")
    else:
        swift = [name for name in changed if name.endswith(".swift")]
        run.check("lint", not swift or run.command(
            ["xcrun", "swift-format", "lint", "--strict", "--configuration", ".swift-format", *swift]) == 0,
            f"{len(swift)} changed Swift files")
        build(run)
        if "build Apple TV" not in run.failed:
            test(run)
        else:
            run.report("test", "SKIP", "the build failed")
    if not run.failed:
        broken = broken_links([name for name in changed if name.endswith(".md")])
        run.check("links", not broken, "; ".join(broken[:5]) or "relative links in changed Markdown resolve")

    surfaces = []
    if not run.failed:
        listed = subprocess.run([sys.executable, str(SCRIPTS / "visual-check.py"), "--list", "--base", base],
                                cwd=ROOT, capture_output=True, text=True)
        surfaces = listed.stdout.split()
        if listed.returncode != 0:
            run.check("views", False, "visual-check.py --list failed: " + listed.stderr.strip()[-200:])
    if not run.failed and (git("rev-parse", "HEAD") != sha or git("status", "--porcelain")):
        run.check("tree", False, "the source changed during the run")

    if run.failed:
        print(f"FAIL premerge {sha[:9]}: {', '.join(run.failed)} failed; log {run.log}")
        return 1
    markers = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")) / "premerge"
    markers.mkdir(exist_ok=True)
    marker = markers / f"{sha}.json"
    marker.write_text(json.dumps({
        "sha": sha, "base": base, "steps": run.results, "visual_surfaces": surfaces,
        "passed_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}, indent=2) + "\n")
    print(f"PASS premerge {sha[:9]}; marker {marker}")
    if surfaces:
        print(f"NEXT this commit changes how {', '.join(surfaces)} look, so it also needs a visual "
              f"check before it merges: python3 {SCRIPTS}/visual-check.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
