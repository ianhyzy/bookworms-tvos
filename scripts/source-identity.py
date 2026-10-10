"""Select and hash release and test sources with the same Git configuration."""

import hashlib
import os
import subprocess


def git_environment(environment=None):
    """Exclude owner configuration while retaining repository ignore rules."""
    environment = (os.environ if environment is None else environment).copy()
    for key in tuple(environment):
        if key in ("GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT") or key.startswith(
            ("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")
        ):
            del environment[key]
    environment["GIT_CONFIG_GLOBAL"] = os.devnull
    environment["GIT_CONFIG_SYSTEM"] = os.devnull
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    return environment


def git_output(root, *arguments, environment=None):
    """Run source-selection Git commands without external excludes files."""
    return subprocess.check_output(
        ["git", "-c", "core.excludesFile=" + os.devnull, *arguments],
        cwd=root,
        env=git_environment(environment),
    )


def git_text(root, *arguments, environment=None):
    return os.fsdecode(git_output(root, *arguments, environment=environment)).strip()


def source_files(root, *, environment=None):
    """Include tracked files and untracked files allowed by repository ignores."""
    names = git_output(
        root, "ls-files", "-z", "--cached", "--others", "--exclude-standard",
        environment=environment,
    )
    return [os.fsdecode(name) for name in sorted(set(names.split(b"\0")) - {b""})]


def source_digest(root, names=None, *, environment=None):
    """Hash filename bytes and contents using the release candidate format."""
    digest = hashlib.sha256()
    for name in source_files(root, environment=environment) if names is None else names:
        path = root / name
        if path.is_file():
            digest.update(os.fsencode(name) + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def source_identity(root, *, environment=None):
    """Record the source commit, status, and content digest for a test handoff."""
    return {
        "commit": git_text(root, "rev-parse", "HEAD", environment=environment),
        "status": git_text(root, "status", "--porcelain", environment=environment),
        "sha256": source_digest(root, environment=environment),
    }
