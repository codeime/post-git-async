#!/usr/bin/env python3
"""Exercise prompt refresh through a real interactive Zsh PTY and real Git.

Run: python3 tests/pty-refresh.py [--plugin /path/to/posh-git-async.plugin.zsh]
The command exits nonzero on a failed scenario and retains its transcript in
the reported temporary directory. --keep-transcripts retains successful runs.
"""

import argparse
import errno
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path
from shlex import quote


DEFAULT_PLUGIN = Path(__file__).resolve().parent.parent / "posh-git-async.plugin.zsh"
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
PROMPT = re.compile(
    r"PGA@([^@\r\n]*)@fd=(-?\d+)@pid=(\d+)@done=([\d.]+)@file=([^@\r\n]*)@END"
)


class Failure(AssertionError):
    pass


def git(*args, cwd=None):
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    return subprocess.run(
        ["git", *args], cwd=cwd, env=env, check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout.strip()


def new_repo(path, branch):
    path.mkdir()
    git("init", "-q", "-b", branch, str(path))
    (path / "tracked.txt").write_text("tracked\n")
    git("add", "tracked.txt", cwd=path)
    git("-c", "user.name=PTY Test", "-c", "user.email=pty@example.invalid",
        "commit", "-qm", "initial", cwd=path)
    return path


def active(pid):
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    state = subprocess.run(
        ["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True
    ).stdout.strip()
    return bool(state) and not state.startswith("Z")


class Shell:
    def __init__(self, cwd, plugin, debounce=None, timeout=None):
        self.cwd = cwd
        self.plugin = plugin
        self.transcript = ""
        self.forced_termination = False
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            env = dict(os.environ, TERM="xterm-256color", GIT_CONFIG_NOSYSTEM="1",
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_OPTIONAL_LOCKS="0")
            os.execve("/bin/zsh", ["zsh", "-d", "-f", "-i"], env)
        try:
            self._setup(debounce, timeout)
        except BaseException:
            (cwd.parent / "transcript.txt").write_text(self.clean())
            self.close()
            raise

    def _setup(self, debounce, timeout):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 240, 0, 0))
        self.read_for(0.08)
        os.write(self.fd, b"stty -echo\n")
        self.read_for(0.08)
        settings = []
        if debounce is not None:
            settings.append(f"POSH_GIT_ASYNC_DEBOUNCE_SECONDS={debounce}")
        if timeout is not None:
            settings.append(f"POSH_GIT_ASYNC_TIMEOUT_SECONDS={timeout}")
        settings.extend([
            f"source {quote(str(self.plugin))}",
            "setopt promptsubst",
            "RPROMPT=",
            "PROMPT='PGA@${POSH_GIT_ASYNC_PROMPT}@fd=${_posh_git_fd}@pid=${_posh_git_job_pid}@done=${_posh_git_last_completed_at}@file=${_posh_git_result_file}@END '",
        ])
        self.send("; ".join(settings), timeout=8)
        self.wait_prompt(lambda p: "main" in p["status"] and p["fd"] == -1, timeout=8)

    def clean(self):
        return ANSI.sub("", self.transcript)

    def prompts(self):
        return [
            {"status": m[1], "fd": int(m[2]), "pid": int(m[3]),
             "done": float(m[4]), "file": m[5], "end": m.end()}
            for m in PROMPT.finditer(self.clean())
        ]

    def latest(self):
        matches = self.prompts()
        if not matches:
            raise Failure("no instrumented prompt appeared")
        return matches[-1]

    def read_for(self, seconds, predicate=None):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate and predicate():
                return True
            ready = select.select([self.fd], [], [], min(0.05, max(0, deadline - time.monotonic())))[0]
            if ready:
                try:
                    data = os.read(self.fd, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        return bool(predicate and predicate())
                    raise
                if not data:
                    return bool(predicate and predicate())
                self.transcript += data.decode("utf-8", "replace")
        return bool(predicate and predicate())

    def wait_prompt(self, predicate, timeout=5, after=None):
        def found():
            prompts = self.prompts()
            if after is not None:
                prompts = prompts[after:]
            return any(predicate(prompt) for prompt in prompts)
        if not self.read_for(timeout, found):
            raise Failure(f"prompt condition timed out after {timeout}s; last={self.prompts()[-3:]}")
        return self.latest()

    def send(self, command, timeout=5):
        before = len(self.prompts())
        marker = f"__CMD_{time.monotonic_ns()}__"
        os.write(self.fd, (command + "; print -r -- " + marker + "\n").encode())
        if not self.read_for(timeout, lambda: marker in self.clean() and len(self.prompts()) > before):
            raise Failure(f"command did not return to a prompt: {command}")
        return self.latest(), before

    def close(self, graceful_timeout=0.25):
        try:
            os.write(self.fd, b"exit\n")
            self.read_for(graceful_timeout)
        except OSError:
            pass
        try:
            waited, _ = os.waitpid(self.pid, os.WNOHANG)
            if not waited:
                self.forced_termination = True
                os.kill(self.pid, signal.SIGTERM)
                os.waitpid(self.pid, 0)
        except ProcessLookupError:
            pass
        os.close(self.fd)
        return not self.forced_termination


def require(condition, message):
    if not condition:
        raise Failure(message)


def count(status):
    match = re.search(r"(?<!\w)\+(\d+)", status)
    return int(match[1]) if match else 0


def await_count(shell, expected, after, timeout=5):
    shell.wait_prompt(lambda p: count(p["status"]) == expected, timeout, after)
    return shell.latest()


def slow_git(repo, log, seconds=0.8, exit_status=0):
    hook = repo / ".git" / "fsmonitor-hook"
    hook.write_text(
        "#!/bin/sh\n"
        f"printf '%s\\n' \"$$\" >> {quote(str(log))}\n"
        f"sleep {seconds} &\n"
        f"printf '%s\\n' \"$!\" >> {quote(str(log))}\n"
        "wait \"$!\"\n"
        f"exit {exit_status}\n"
    )
    hook.chmod(0o755)
    git("config", "core.fsmonitor", str(hook), cwd=repo)
    return hook


def test_after_completion(root, plugin, debounce=None):
    repo = new_repo(root / "repo", "main")
    shell = Shell(repo, plugin, debounce=debounce)
    try:
        if debounce and debounce > 0.25:
            shell.read_for(0.35)
        before = len(shell.prompts())
        shell.send('touch first.txt; print -r -- "DELTA=$(( (EPOCHREALTIME-_posh_git_last_completed_at)*1000 ))"')
        match = re.search(r"DELTA=([\d.]+)", shell.clean())
        require(match is not None, "completion-to-touch timing was not printed")
        delta = float(match[1])
        window = 250 if debounce is None else debounce * 1000
        if window:
            require(delta < window, f"touch landed outside {window:.0f}ms window: {delta:.1f}ms")
        await_count(shell, 1, before, timeout=max(4, (debounce or 0.25) + 3))
        require("?? first.txt" in git("status", "--porcelain", cwd=repo), "Git did not see touch")
        return f"touch +{delta:.0f}ms after completion; +1 rendered without input"
    finally:
        shell.close()
        save_transcript(root, shell)


def test_running_worker(root, plugin, many=False):
    repo = new_repo(root / "repo", "main")
    shell = Shell(repo, plugin)
    try:
        log = root / "hook-pids"
        slow_git(repo, log)
        names = ["one.txt", "two.txt", "three.txt", "four.txt"] if many else ["one.txt", "two.txt"]
        for index, name in enumerate(names):
            current, _ = shell.send(f"touch {name}")
            require(current["fd"] >= 0, f"worker completed before command {index + 1}; slow Git fixture inactive")
            if index == 0:
                require(shell.read_for(2, lambda: log.exists() and len(log.read_text().splitlines()) >= 2),
                        "real Git fsmonitor hook did not enter the scan")
        require(count(shell.latest()["status"]) == 0,
                "all changes were already rendered before the idle redraw assertion")
        before = len(shell.prompts())
        await_count(shell, len(names), before, timeout=8)
        require(len(git("status", "--porcelain", cwd=repo).splitlines()) >= len(names),
                "Git did not see every touched file")
        return f"{len(names)} commands during real Git hook delay; +{len(names)} rendered"
    finally:
        shell.close()
        save_transcript(root, shell)


def test_switch_directories(root, plugin):
    first = new_repo(root / "first", "main")
    second = new_repo(root / "second", "other")
    outside = root / "outside"
    outside.mkdir()
    shell = Shell(first, plugin)
    try:
        slow_git(first, root / "hook-pids", seconds=1.0)
        current, _ = shell.send("touch pending.txt")
        require(current["fd"] >= 0, "first repository worker was not running")
        _, before = shell.send(f"cd {quote(str(second))}")
        shell.wait_prompt(lambda p: "other" in p["status"], timeout=5, after=before)
        shell.read_for(1.3)
        require("other" in shell.latest()["status"] and "main" not in shell.latest()["status"],
                "old repository prompt returned after switch")
        shell.send(f"cd {quote(str(outside))}")
        shell.read_for(0.3)
        require(shell.latest()["status"] == "", "Git status appeared in non-Git directory")
        return "in-flight main -> other -> non-Git; no stale prompt"
    finally:
        shell.close()
        save_transcript(root, shell)


def test_inside_gitdir(root, plugin):
    repo = new_repo(root / "repo", "main")
    shell = Shell(repo, plugin)
    try:
        _, before = shell.send("cd .git")
        shell.wait_prompt(lambda p: "GIT_DIR!" in p["status"], timeout=5, after=before)
        require("GIT_DIR!" in shell.latest()["status"], "inside .git did not render GIT_DIR!")
        _, before = shell.send("cd ..")
        shell.wait_prompt(lambda p: "main" in p["status"] and "GIT_DIR!" not in p["status"],
                          timeout=5, after=before)
        return "same repository .git -> root renders correct context"
    finally:
        shell.close()
        save_transcript(root, shell)


def test_git_flow(root, plugin):
    repo = new_repo(root / "repo", "main")
    shell = Shell(repo, plugin)
    try:
        steps = [
            ("print changed >> tracked.txt", lambda s: "~1" in s and " !" in s),
            ("git add tracked.txt", lambda s: "~1" in s and " ~" in s and " !" not in s),
            ("git -c user.name=PTY -c user.email=pty@example.invalid commit -qm update",
             lambda s: "main" in s and "~1" not in s and " !" not in s),
            ("rm tracked.txt", lambda s: "-1" in s and " !" in s),
            ("git checkout -qb branch-two", lambda s: "branch-two" in s and "-1" in s),
            ("git restore tracked.txt", lambda s: "branch-two" in s and "-1" not in s),
        ]
        timings = []
        for index, (command, expected) in enumerate(steps):
            before = len(shell.prompts())
            marker = f"STEP_START_{index}="
            shell.send(f'print -r -- "{marker}$(( (EPOCHREALTIME-_posh_git_last_completed_at)*1000 ))"; {command}')
            match = re.search(re.escape(marker) + r"([\d.]+)", shell.clean())
            require(match is not None, f"step {index + 1} did not report timing")
            delta = float(match[1])
            require(delta < 250, f"step {index + 1} started {delta:.1f}ms after completion")
            timings.append(delta)
            shell.wait_prompt(lambda p: expected(p["status"]), timeout=5, after=before)
            require(expected(shell.latest()["status"]), f"step {index + 1} final prompt is stale")
        require(git("branch", "--show-current", cwd=repo) == "branch-two", "branch switch did not occur")
        require(not git("status", "--porcelain", cwd=repo), "final Git tree is not clean")
        return f"modify/add/commit/delete/branch/restore; start deltas {','.join(f'{d:.0f}' for d in timings)}ms"
    finally:
        shell.close()
        save_transcript(root, shell)


def test_config(root, plugin, rapid=False):
    repo = new_repo(root / "repo", "main")
    git("config", "bash.enableGitStatus", "true", cwd=repo)
    shell = Shell(repo, plugin)
    try:
        shell.read_for(0.3)
        if rapid:
            _, before = shell.send("git config bash.enableGitStatus false")
            shell.wait_prompt(lambda p: p["status"] == "", timeout=3, after=before)
            _, before = shell.send('git config bash.enableGitStatus true; print -r -- "TOGGLE_MS=$(( (EPOCHREALTIME-_posh_git_hint_checked_at)*1000 ))"')
            elapsed = re.findall(r"TOGGLE_MS=([\d.]+)", shell.clean())
            require(elapsed and float(elapsed[-1]) < 250,
                    f"false-to-true switch missed 250ms window: {elapsed[-1] if elapsed else 'missing'}")
            shell.wait_prompt(lambda p: "main" in p["status"], timeout=5, after=before)
            before = len(shell.prompts())
            shell.send("touch after-toggle.txt")
            await_count(shell, 1, before, timeout=5)
            return f"false -> true in {float(elapsed[-1]):.0f}ms; final enabled status rendered"
        _, before = shell.send("git config bash.enableGitStatus false")
        shell.wait_prompt(lambda p: p["status"] == "", timeout=3, after=before)
        shell.read_for(0.35)
        require(shell.latest()["status"] == "", "disabled status came back")
        _, before = shell.send("git config bash.enableGitStatus true")
        shell.wait_prompt(lambda p: "main" in p["status"], timeout=5, after=before)
        return "disabled prompt cleared; re-enabled prompt restored"
    finally:
        shell.close()
        save_transcript(root, shell)


def test_zero(root, plugin):
    repo = new_repo(root / "repo", "main")
    shell = Shell(repo, plugin, debounce=0)
    try:
        before = len(shell.prompts())
        shell.send("touch zero.txt")
        await_count(shell, 1, before)
        return "debounce=0; +1 rendered"
    finally:
        shell.close()
        save_transcript(root, shell)


def test_timeout_excludes_wait(root, plugin):
    repo = new_repo(root / "repo", "main")
    shell = Shell(repo, plugin, debounce=0.6, timeout=0.1)
    try:
        first, before = shell.send('print -r -- "TOUCH_DELTA_MS=$(( (EPOCHREALTIME-_posh_git_last_completed_at)*1000 ))"; touch waiting.txt')
        touch_delta = re.findall(r"TOUCH_DELTA_MS=([\d.]+)", shell.clean())
        require(touch_delta and float(touch_delta[-1]) < 600,
                f"touch missed 600ms debounce window: {touch_delta[-1] if touch_delta else 'missing'}")
        require(first["pid"] > 0, "debounce waiter did not start")
        shell.read_for(0.2)
        second, _ = shell.send('print -r -- "WAIT_REMAIN_MS=$(( (_posh_git_job_started_at-EPOCHREALTIME)*1000 ))"; :')
        remaining = re.findall(r"WAIT_REMAIN_MS=([\d.]+)", shell.clean())
        require(remaining and float(remaining[-1]) > 0,
                f"worker was not still inside debounce wait: {remaining[-1] if remaining else 'missing'}")
        require(second["pid"] == first["pid"],
                f"timeout killed a worker still waiting for debounce: {first['pid']} -> {second['pid']}")
        await_count(shell, 1, before, timeout=5)
        return (f"touch +{float(touch_delta[-1]):.0f}ms; "
                f"remaining wait {float(remaining[-1]):.0f}ms after 200ms; same worker completed")
    finally:
        shell.close()
        save_transcript(root, shell)


def test_scan_timeout(root, plugin):
    repo = new_repo(root / "repo", "main")
    shell = Shell(repo, plugin, timeout=0.2)
    try:
        log = root / "hook-pids"
        slow_git(repo, log, seconds=3.0, exit_status=1)
        first, before = shell.send("touch slow.txt")
        require(first["pid"] > 0 and first["file"], "slow Git worker did not start")
        require(shell.read_for(2, lambda: log.exists() and len(log.read_text().splitlines()) >= 2),
                "real Git fsmonitor hook did not start")
        hook_pids = [int(line) for line in log.read_text().splitlines()]
        shell.read_for(0.3)
        shell.send("git config --unset core.fsmonitor")
        await_count(shell, 1, before, timeout=5)
        require(not active(first["pid"]), f"timed-out worker {first['pid']} survived")
        require(all(not active(pid) for pid in hook_pids),
                f"timed-out Git hook children survived: {hook_pids}")
        require(not Path(first["file"]).exists(),
                f"timed-out worker result file survived: {first['file']}")
        return "timed-out real Git hook cancelled; fresh worker rendered +1"
    finally:
        shell.close()
        save_transcript(root, shell)


def test_exit_cleanup(root, plugin):
    repo = new_repo(root / "repo", "main")
    shell = Shell(repo, plugin)
    log = root / "hook-pids"
    try:
        slow_git(repo, log, seconds=3.0)
        current, _ = shell.send("touch exit.txt")
        require(current["pid"] > 0 and current["file"], "no live worker/result file at exit")
        require(shell.read_for(2, lambda: log.exists() and len(log.read_text().splitlines()) >= 2),
                "real Git fsmonitor child did not start")
        child_pids = [int(line) for line in log.read_text().splitlines()]
        worker_pid, result_file = current["pid"], current["file"]
        save_transcript(root, shell)
        natural_exit = shell.close(graceful_timeout=2)
        shell = None
        time.sleep(0.3)
        require(natural_exit, "shell needed forced termination instead of zshexit cleanup")
        require(not active(worker_pid), f"worker {worker_pid} survived shell exit")
        require(all(not active(pid) for pid in child_pids), f"Git hook children survived shell exit: {child_pids}")
        require(not Path(result_file).exists(), f"temporary result file survived exit: {result_file}")
        return f"worker {worker_pid}, {len(child_pids)} hook child, result file removed"
    finally:
        if shell is not None:
            shell.close()
            save_transcript(root, shell)


def save_transcript(root, shell):
    (root / "transcript.txt").write_text(shell.clean())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin", type=Path, default=DEFAULT_PLUGIN,
                        help="plugin source file (default: repository copy)")
    parser.add_argument("--keep-transcripts", action="store_true")
    args = parser.parse_args()
    plugin = args.plugin.resolve()
    if not plugin.is_file():
        parser.error(f"plugin not found: {plugin}")
    cases = [
        ("completed worker, 250ms touch", test_after_completion, {}),
        ("second change while worker runs", test_running_worker, {}),
        ("rapid commands coalesce", test_running_worker, {"many": True}),
        ("repository and non-Git switch", test_switch_directories, {}),
        ("same repository .git switch", test_inside_gitdir, {}),
        ("real Git state flow", test_git_flow, {}),
        ("disable and re-enable", test_config, {}),
        ("rapid disable and re-enable", test_config, {"rapid": True}),
        ("debounce zero", test_zero, {}),
        ("longer 600ms debounce", test_after_completion, {"debounce": 0.6}),
        ("timeout excludes debounce wait", test_timeout_excludes_wait, {}),
        ("real Git scan timeout", test_scan_timeout, {}),
        ("shell exit cleanup", test_exit_cleanup, {}),
    ]
    passed = failed = 0
    for name, run, options in cases:
        root = Path(tempfile.mkdtemp(prefix="posh-git-pty-"))
        started = time.monotonic()
        try:
            detail = run(root, plugin, **options)
            passed += 1
            print(f"PASS {name} ({time.monotonic() - started:.2f}s): {detail}", flush=True)
            if not args.keep_transcripts:
                shutil.rmtree(root)
            else:
                print(f"  transcript: {root / 'transcript.txt'}", flush=True)
        except Exception as error:
            failed += 1
            print(f"FAIL {name} ({time.monotonic() - started:.2f}s): {error}", flush=True)
            print(f"  kept fixture and transcript: {root}", flush=True)
    print(f"passed={passed} failed={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
