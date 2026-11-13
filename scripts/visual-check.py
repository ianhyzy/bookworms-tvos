#!/usr/bin/env python3
"""Captures the views a change touches, before and after it, for an agent to review.

    python3 scripts/visual-check.py                  capture the views the change touches
    python3 scripts/visual-check.py --list           print the views the change touches
    python3 scripts/visual-check.py --surfaces shelf,bookWall    capture these views instead
    python3 scripts/visual-check.py --head <commit> --base <commit>    check another change
    python3 scripts/visual-check.py --record pass    record the agent's verdict for HEAD

The script maps the files changed between the base and HEAD to views (`RULES`), builds both
commits for the Apple TV simulator, and runs each view's launches (`SHOTS`) on one slim
simulator that it creates and deletes. Each launch saves a screenshot, and a launch with motion
also saves a short recording, reduced to twelve frames in one image, because agents read
images, not video. The app shows the owner's real library from an exported example profile, so the bundle
stays in the ignored `.local/visual-check/` folder: never commit or publish it.

The bundle's `REVIEW.md` gives a reviewing agent the images and a fixed list of questions.
After the agent reports `VERDICT: pass`, `--record pass` writes the visual-check marker that the
workspace's merge gate needs for a commit that touches a view. docs/TESTING.md, Visual check,
describes the review step and what the check can't judge.

Run it with the Bash sandbox off, because xcodebuild can't reach the Metal toolchain inside it.
"""
import argparse
import bisect
import datetime
import importlib.util
import itertools
import json
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = Path(__file__).resolve().parent.relative_to(ROOT)
BUNDLE_ID = "gay.ian.Bookworms"
PLATFORM = "Apple TV"

SURFACES = {
    "shelf": "My Shelf",
    "details": "book details",
    "yearInReview": "Year in Review",
    "bookWall": "Book Wall",
    "settings": "Settings",
    "social": "Feed, Compare Shelves, Book Club, and Friends' Picks",
    "ambient": "ambient mode",
    "welcome": "the welcome and sign-in screens",
    "topShelf": "the Home Screen's Top Shelf",
    "other": "a view this script has no rule for",
}
EVERY_VIEW = [name for name in SURFACES if name != "other"]
# A changed file under Bookworms/, BookwormsTopShelf/, or Shared/ whose path matches a pattern
# touches those views. A file that matches no pattern touches "other" when it is under Views/,
# is a shader or an asset, or has a name that suggests drawing code (`DRAWS`).
RULES = [
    (r"Views/ShelfView|Views/ShelfControls|Models/ShelfLayout", ["shelf", "details"]),
    (r"Views/BookDetailView|Views/RatingsView", ["details"]),
    (r"YearInReview", ["yearInReview"]),
    (r"BookWall|HouseOfLeaves", ["bookWall"]),
    # Spine lettering and series looks draw on shelf spines, in details, and on Book Wall.
    (r"SpineText|SeriesDesigns|GoogleFontLibrary", ["shelf", "details", "bookWall"]),
    (r"Views/SettingsView", ["settings"]),
    (r"SocialViews|ComparisonBookshelf|SocialPresentation", ["social"]),
    (r"Ambient", ["ambient"]),
    (r"LibraryWelcomeView|HardcoverConnectionView|QRCodeView", ["welcome", "settings"]),
    (r"TopShelf", ["topShelf"]),
    (r"Views/CoverView|Views/BookText|Views/SpineView|Models/SpineStyle|Models/BookPresentation"
     r"|Models/AppAppearance|Models/ViewPreferences|BookwormsApp\.swift|\.xcassets/", EVERY_VIEW),
]
DRAWS = r"/Views/|\.metal$|\.xcassets/|Presentation|Layout|Style|Appearance|Spine|Cover|Artwork|Font|Color"


@dataclass
class Shot:
    """One launch of the app: a screenshot `wait` seconds in, and a recording when `motion`."""
    name: str
    arguments: list
    wait: int
    motion: bool = False


# `{book}` becomes the ID of the example profile's first book.
SHOTS = {
    "shelf": [Shot("launch", [], 30)],
    "details": [Shot("details", ["--show-book={book}"], 30)],
    "yearInReview": [Shot("year", ["--start-view=yearInReview"], 30)],
    "bookWall": [
        Shot("drop", ["--start-view=bookWall"], 50, motion=True),
        Shot("open-book", ["--start-view=bookWall", "--book-wall-open-entry"], 60, motion=True),
    ],
}

QUESTIONS = """\
1. **Regression.** Compare before and after. Did anything get worse that the change doesn't
   explain: something missing, moved, resized, recolored, or set in another font, or a new gap?
   Physics scenes land differently on every run, so judge the rules below, not exact positions.
2. **Physical realism.** Do stacked books lie flat and level on what they rest on, touching it,
   with no gap, overlap, float, or lean on nothing? Is every book book-shaped, its spine several
   times as long as it is thick?
3. **Legible lettering.** Can you read the spine and cover titles and the app's text? Is any
   title shortened or tiny where the spine has room for it?
4. **Camera faces the action.** In 3D scenes and motion strips, does the subject stay on screen
   in every frame, with no book or card cut off by the screen's edge?
5. **Motion.** In a motion strip, does each frame follow from the one before, with no jump, no
   pop, and no book passing through another? Does a pulled book come straight out toward the
   viewer?
6. **Focus.** Is exactly one item visibly focused, and is the sidebar closed at launch? When
   you can't see which item is focused, answer CAN'T TELL.
7. **Nothing clipped or overlapping.** Does all text and every control sit inside its container
   and the screen, with no text over other text?
8. **No eyebrow labels.** Did the change add small, tracked, all-caps text above a title?
"""


def git(*arguments):
    return subprocess.run(["git", *arguments], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def quiet(arguments, **options):
    return subprocess.run(list(map(str, arguments)), capture_output=True, text=True, **options)


def touched(files):
    """Returns the views that the changed `files` touch, in `SURFACES` order."""
    found = set()
    for name in files:
        if not re.match(r"(Bookworms|BookwormsTopShelf|Shared)/", name):
            continue
        matched = [view for pattern, views in RULES if re.search(pattern, name) for view in views]
        if not matched and re.search(DRAWS, name):
            matched = ["other"]
        found.update(matched)
    return [name for name in SURFACES if name in found]


def example_profile(main):
    """Returns the folder that holds the owner's exported example profile, or None."""
    exports = sorted((main / ".local").glob("example-profile-*"), key=lambda folder: folder.stat().st_mtime)
    for folder in [ROOT / "ExampleProfile", main / "ExampleProfile", *reversed(exports)]:
        if (folder / "library-v1.json").exists():
            return folder
    return None


def build(sha, profile, work, log):
    """Builds the Debug simulator app of commit `sha` with the example profile and returns it."""
    products = work / "build" / sha[:9]
    app = products / "Build/Products/Debug-appletvsimulator/Bookworms.app"
    if app.exists():
        return app
    source = work / "source" / sha[:9]
    shutil.rmtree(source, ignore_errors=True)
    source.mkdir(parents=True)
    exported = quiet(["git", "archive", "--output", source / "source.tar", sha], cwd=ROOT)
    if exported.returncode != 0 or quiet(["tar", "-xf", source / "source.tar", "-C", source]).returncode != 0:
        sys.exit(f"Couldn't export the source of {sha[:9]}: {exported.stderr.strip()}")
    shutil.copytree(profile, source / "ExampleProfile", dirs_exist_ok=True)
    built = subprocess.run([
        "xcodebuild", "-quiet", "-project", "Bookworms.xcodeproj", "-scheme", "Bookworms",
        "-configuration", "Debug", "-destination", "generic/platform=tvOS Simulator",
        "-derivedDataPath", str(products), "CODE_SIGNING_ALLOWED=NO", "build"],
        cwd=source, stdout=log, stderr=subprocess.STDOUT)
    if built.returncode != 0 or not app.exists():
        sys.exit(f"The build of {sha[:9]} failed; log {log.name}")
    return app


def sibling(name):
    """Loads another script of this folder as a module; their hyphenated names can't be imported."""
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def create_simulator(name, runner):
    """Creates, without booting it, one Apple TV simulator at 1080p on the newest tvOS runtime.

    Stops first when one more simulator would break the workspace's simulator limits, and
    turns off Device Hub's tvOS sound as the test runner (`runner`) does.
    """
    limit = sibling("premerge").simulator_limit()
    if limit:
        sys.exit(f"No simulator started: {limit}.")
    runner.mute_simulator_audio()
    inventory = json.loads(quiet(["xcrun", "simctl", "list", "--json"]).stdout)
    runtime = runner.select_runtimes(inventory, None)[0][1]
    device = next((device for device in inventory["devicetypes"]
                   if "Apple-TV-4K-3rd-generation-1080p" in device["identifier"]), None)
    if not runtime or not device:
        sys.exit("No tvOS runtime or Apple TV 4K (at 1080p) device type is installed.")
    return quiet(["xcrun", "simctl", "create", name, device["identifier"], runtime["identifier"]]).stdout.strip()


def motion_strip(clip, strip, scratch, tiles="3x4", scale="640:-2"):
    """Reduces a recording to twelve frames in one image, then halves the recording's size.

    The frames are spaced by how much the picture changes, not by time, so most of them show
    the motion and few show a loading screen or a still view. ffmpeg's scene score measures the
    change from the frame before; a cut counts no more than a fast frame of motion (0.02), and
    change below 0.001, such as a spinner, counts as none.
    """
    shutil.rmtree(scratch, ignore_errors=True)
    scratch.mkdir(parents=True)
    quiet(["ffmpeg", "-loglevel", "error", "-i", clip, "-vf",
           f"fps=10,scale={scale},select='gte(scene,0)',metadata=print:file=scores.txt",
           "-fps_mode", "vfr", "-q:v", "4", "%05d.jpg"], cwd=scratch)
    frames = sorted(scratch.glob("*.jpg"))
    scores = [min(max(float(score) - 0.001, 0), 0.02)
              for score in re.findall(r"scene_score=([\d.]+)", (scratch / "scores.txt").read_text())]
    if frames and len(scores) == len(frames):
        if not sum(scores):
            scores = [1] * len(frames)
        moved = list(itertools.accumulate(scores))
        for index in range(12):
            frame = frames[bisect.bisect_left(moved, moved[-1] * (index + 0.5) / 12)]
            shutil.copy(frame, scratch / f"{index}.jpg")
        quiet(["ffmpeg", "-loglevel", "error", "-y", "-i", scratch / "%d.jpg", "-vf", f"tile={tiles}",
               "-frames:v", "1", strip])
    shutil.rmtree(scratch, ignore_errors=True)
    small = clip.with_suffix(".small.mp4")
    quiet(["ffmpeg", "-loglevel", "error", "-y", "-i", clip, "-vf", "scale=trunc(iw/4)*2:-2", "-an",
           "-crf", "30", small])
    if small.exists():
        small.replace(clip)


def capture(simulator, shot, book, prefix):
    """Launches the app for one shot and saves `<prefix>.png`, and `<prefix>-motion.png` for motion."""
    arguments = ["--example-profile"] + [argument.format(book=book) for argument in shot.arguments]
    quiet(["xcrun", "simctl", "terminate", simulator, BUNDLE_ID])
    recorder = None
    clip = prefix.with_name(prefix.name + ".mp4")
    if shot.motion:
        recorder = subprocess.Popen(["xcrun", "simctl", "io", simulator, "recordVideo", "--codec", "h264",
                                     "--force", str(clip)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(2)
    quiet(["xcrun", "simctl", "launch", simulator, BUNDLE_ID, *arguments])
    time.sleep(shot.wait)
    quiet(["xcrun", "simctl", "io", simulator, "screenshot", prefix.with_name(prefix.name + ".png")])
    if recorder:
        recorder.send_signal(signal.SIGINT)
        recorder.wait(timeout=60)
        motion_strip(clip, prefix.with_name(prefix.name + "-motion.png"), prefix.with_name("scratch"))
    quiet(["xcrun", "simctl", "terminate", simulator, BUNDLE_ID])


def pair(before, after, out):
    """Joins two screenshots side by side, before on the left."""
    if not (before.exists() and after.exists()):
        return False
    quiet(["ffmpeg", "-loglevel", "error", "-y", "-i", before, "-i", after, "-filter_complex",
           "[0]scale=-2:900[a];[1]scale=-2:900[b];[a][b]hstack", out])
    return out.exists()


def review_brief(manifest):
    lines = [
        "# Visual check", "",
        f"Change: `{manifest['base'][:9]}` (before) to `{manifest['head'][:9]}` (after).", "",
        "Commits:", *[f"- {subject}" for subject in manifest["commits"]], "",
        "Changed files:", *[f"- `{name}`" for name in manifest["files"]], "",
        "## What to do", "",
        "Read every image listed below with the Read tool; they are in this file's folder, and",
        "you need no other file. They show the owner's private library:",
        "don't copy them anywhere or quote book lists. For each shot, answer the questions that",
        "apply with PASS, FAIL, or CAN'T TELL and one line of evidence that names the image and",
        "the place in it. In a pair image, before is on the left and after is on the right. A",
        "motion image holds twelve frames of one launch in time order, left to right, then down,",
        "chosen where the picture changes most, so they aren't evenly spaced in time.",
        "Judge the after images against the questions, and use the before images to find what",
        "changed. Don't judge taste, and don't guess: a detail too small to see is CAN'T TELL.", "",
        "End with a list of regressions (or \"none\"), then one line: `VERDICT: pass` when no",
        "answer is FAIL, else `VERDICT: fail`.", "",
        "## Questions", "", QUESTIONS, "## Shots", "",
    ]
    for shot in manifest["shots"]:
        lines.append(f"### {shot['platform']}: {SURFACES[shot['surface']]}, {shot['name']}")
        lines += [f"- `{image}`" for image in shot["images"]] + [""]
    if manifest["not_captured"]:
        lines += ["## Not captured", "",
                  "These touched views have no launch in this script, so nobody has looked at them:",
                  *[f"- {SURFACES[name]}" for name in manifest["not_captured"]], ""]
    lines += ["## What this check can't judge", "",
              "Taste, performance, and focus behavior on a physical Apple TV. Simulator screenshots",
              "also can't show how the screen reads from across a room."]
    return "\n".join(lines) + "\n"


def record(verdict, note):
    """Writes or removes the visual-check marker for HEAD, which must have a bundle."""
    sha = git("rev-parse", "HEAD")
    bundle = ROOT / ".local" / "visual-check" / sha[:9]
    try:
        manifest = json.loads((bundle / "manifest.json").read_text())
    except (OSError, ValueError):
        sys.exit(f"No bundle for {sha[:9]}. Run python3 {SCRIPTS}/visual-check.py first.")
    marker = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")) / "premerge" / f"{sha}.visual.json"
    if verdict == "fail":
        marker.unlink(missing_ok=True)
        print(f"No visual-check marker for {sha[:9]}. Fix the regressions, commit, and capture again.")
        return
    marker.parent.mkdir(exist_ok=True)
    marker.write_text(json.dumps({
        "sha": sha, "verdict": "pass", "note": note, "bundle": str(bundle),
        "surfaces": manifest["surfaces"], "not_captured": manifest["not_captured"],
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}, indent=2) + "\n")
    print(f"PASS visual check {sha[:9]}; marker {marker}")
    if manifest["not_captured"]:
        print("Not captured, so check by hand: " + ", ".join(SURFACES[name] for name in manifest["not_captured"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--base", default="origin/main", help="commit to compare with (default: origin/main)")
    parser.add_argument("--head", default="HEAD", help="commit to check (default: HEAD)")
    parser.add_argument("--surfaces", help="comma-separated views to capture instead of the ones the diff touches: "
                        + ", ".join(SURFACES))
    parser.add_argument("--list", action="store_true", help="print the views the change touches and stop")
    parser.add_argument("--record", choices=["pass", "fail"], help="record the reviewing agent's verdict for HEAD")
    parser.add_argument("--note", default="", help="with --record: one line about the review")
    parser.add_argument("--keep-builds", action="store_true", help="keep both builds for another run")
    arguments = parser.parse_args()
    if arguments.record:
        return record(arguments.record, arguments.note)

    head = git("rev-parse", arguments.head)
    base = git("merge-base", arguments.base, head)
    files = [name for name in git("diff", "--name-only", base, head).splitlines() if name]
    surfaces = touched(files)
    if arguments.list:
        print("\n".join(surfaces))
        return
    if arguments.surfaces:
        surfaces = arguments.surfaces.split(",")
        unknown = [name for name in surfaces if name not in SURFACES]
        if unknown:
            sys.exit(f"Unknown views: {', '.join(unknown)}. Choose from: {', '.join(SURFACES)}")
    if not surfaces:
        print(f"SKIP visual check {head[:9]}: the change touches no view.")
        return
    if head == git("rev-parse", "HEAD") and git("status", "--porcelain"):
        sys.exit("Commit or remove the uncommitted changes first: the check captures the HEAD commit.")
    main_checkout = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")).parent
    profile = example_profile(main_checkout)
    if not profile:
        sys.exit(f"No example profile. Export one: python3 -I {SCRIPTS}/export-example-profile.py --out ExampleProfile")
    library = json.loads((profile / "library-v1.json").read_text())
    book = library["sources"][0]["books"][0]["id"]

    work = ROOT / ".local" / "visual-check"
    bundle = work / head[:9]
    shutil.rmtree(bundle, ignore_errors=True)
    bundle.mkdir(parents=True)
    captured = [name for name in surfaces if name in SHOTS]
    missing = []
    manifest = {"head": head, "base": base, "surfaces": surfaces, "files": files, "shots": [],
                "commits": git("log", "--format=%s", f"{base}..{head}").splitlines(),
                "not_captured": [name for name in surfaces if name not in SHOTS]}
    if captured:
        with (bundle / "capture.log").open("w") as log:
            apps = {"before": build(base, profile, work, log), "after": build(head, profile, work, log)}
            runner = sibling("test-local")
            simulator = create_simulator(f"visual-check-{head[:9]}", runner)
            try:
                # The app loads covers and fonts over the network and draws with Metal; neither
                # needs a simslim category.
                runner.boot_simulator(simulator)
                for label, app in apps.items():
                    quiet(["xcrun", "simctl", "uninstall", simulator, BUNDLE_ID])
                    quiet(["xcrun", "simctl", "install", simulator, app])
                    for surface in captured:
                        for shot in SHOTS[surface]:
                            print(f"capturing {label} {surface} {shot.name}", flush=True)
                            capture(simulator, shot, book, bundle / f"{surface}-{shot.name}-{label}")
            finally:
                quiet(["xcrun", "simctl", "shutdown", simulator])
                quiet(["xcrun", "simctl", "delete", simulator])
        for surface in captured:
            for shot in SHOTS[surface]:
                stem = f"{surface}-{shot.name}"
                images = [f"{stem}-before.png", f"{stem}-after.png", f"{stem}-pair.png",
                          f"{stem}-before-motion.png", f"{stem}-after-motion.png"]
                pair(bundle / images[0], bundle / images[1], bundle / images[2])
                manifest["shots"].append({"platform": PLATFORM, "surface": surface, "name": shot.name,
                                          "images": [image for image in images if (bundle / image).exists()]})
                if not all((bundle / image).exists() for image in images[:2]):
                    missing.append(f"{surface} {shot.name}")
        if not arguments.keep_builds:
            shutil.rmtree(work / "build", ignore_errors=True)
            shutil.rmtree(work / "source", ignore_errors=True)
    if missing:
        sys.exit(f"The capture failed for {', '.join(missing)}; log {bundle / 'capture.log'}")
    (bundle / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (bundle / "REVIEW.md").write_text(review_brief(manifest))
    print(f"Bundle: {bundle}")
    if manifest["not_captured"]:
        print("Not captured, so check by hand: " + ", ".join(SURFACES[name] for name in manifest["not_captured"]))
    print(f"NEXT have a Sonnet agent follow {bundle / 'REVIEW.md'} and report; when its last line is "
          f"VERDICT: pass, run python3 {SCRIPTS}/visual-check.py --record pass")


if __name__ == "__main__":
    # A stopped run still deletes its simulator.
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    main()
