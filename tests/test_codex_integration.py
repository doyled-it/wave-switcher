"""Exercise the real adapters/installers with Wave's external CLI stubbed."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import unittest

SPOON = Path(__file__).resolve().parents[1] / "WaveSwitcher.spoon"


class CodexHookTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        (root / "bin").mkdir()
        self.log = root / "wsh.jsonl"
        self.state = root / "metadata.json"
        wsh = root / "bin/wsh"
        wsh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys, time
with open(os.environ['WSH_LOG'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
path = pathlib.Path(os.environ['WSH_STATE'])
meta = json.loads(path.read_text()) if path.exists() else {}
if sys.argv[1] == 'setmeta':
    for pair in sys.argv[4:]:
        key, value = pair.split('=', 1)
        meta[key] = value
    path.write_text(json.dumps(meta))
elif sys.argv[1] == 'getmeta':
    if os.environ.get('WSH_READ_BARRIER'):
        barrier = pathlib.Path(os.environ['WSH_READ_BARRIER'])
        (barrier / 'ready').touch()
        deadline = time.monotonic() + 2
        while not (barrier / 'release').exists() and time.monotonic() < deadline:
            time.sleep(.01)
    print(meta.get(sys.argv[-1], ''))
''')
        wsh.chmod(0o755)
        self.env = dict(os.environ, TMPDIR=str(root), WSH_LOG=str(self.log), WSH_STATE=str(self.state),
                        PATH=str(root / "bin") + ":/usr/bin:/bin",
                        WAVETERM_TABID="test-tab", WAVETERM_BLOCKID="test-block")
        self.env.pop("WSW_DEBUG", None)
        self.env.pop("WSW_AGENT", None)
        self.invoke("SessionStart", source="startup")

    def invoke(self, event, **extra):
        payload = dict(session_id="codex-session", hook_event_name=event,
                       cwd="/tmp/demo", model="demo", permission_mode="default",
                       transcript_path=None)
        payload.update(extra)
        result = subprocess.run(["/bin/zsh", str(SPOON / "wave-codex-hook.sh"), event],
                                input=json.dumps(payload), text=True,
                                capture_output=True, env=self.env, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "", "Status hooks must not steer the agent")
        calls = [json.loads(s) for s in self.log.read_text().splitlines()] if self.log.exists() else []
        self.log.unlink(missing_ok=True)
        return calls

    def assert_color(self, calls, expected):
        colors = [a.split("=", 1)[1] for c in calls for a in c if a.startswith("tab:flagcolor=")]
        self.assertTrue(colors, calls)
        self.assertEqual(colors[-1], expected)
        self.assertTrue(any(a.startswith("waveswitcher:activity=") for c in calls for a in c))

    def test_codex_resume_identity(self):
        calls = self.invoke("SessionStart", source="startup")
        self.assert_color(calls, "#58c142")
        self.assertTrue(any("codex:resume=codex-session" in c for c in calls))
        self.assertTrue(any("claude:resume=" in c for c in calls))
        calls = self.invoke("SessionEnd", reason="other")
        self.assertIn(["setmeta", "-b", "this", "codex:resume=", "codex:home="], calls)

    def test_working_idle_interrupt_and_compaction(self):
        for event, color in [("UserPromptSubmit", "#4a9eff"),
                             ("PostToolUse", "#4a9eff"), ("Stop", "#58c142"),
                             ("Interrupt", "#58c142"), ("PreCompact", "#e86f9e"),
                             ("PostCompact", "#4a9eff")]:
            with self.subTest(event=event):
                self.assert_color(self.invoke(event), color)

    def test_subagents_survive_compaction_and_stops_are_idempotent(self):
        self.invoke("SessionStart", source="startup")
        self.assert_color(self.invoke("SubagentStart", agent_id="agent-a"), "#a970ff")
        self.invoke("SubagentStart", agent_id="agent-b")
        self.invoke("SessionStart", source="compact")
        self.assert_color(self.invoke("Stop"), "#a970ff")
        self.invoke("SubagentStop", agent_id="agent-a")
        self.assert_color(self.invoke("SubagentStop", agent_id="agent-a"), "#a970ff")
        self.assert_color(self.invoke("SubagentStop", agent_id="agent-b"), "#58c142")

    def test_outside_wave_does_nothing(self):
        self.env.pop("WAVETERM_TABID")
        self.env.pop("WAVETERM_BLOCKID")
        self.assertEqual(self.invoke("SessionStart", source="startup"), [])

    def test_claude_markers_do_not_affect_codex(self):
        root = Path(self.tmp.name) / "wsw-subs-test-tab.d"
        root.mkdir()
        (root / "claude-agent").touch()
        self.assert_color(self.invoke("Stop"), "#58c142")
        self.assertTrue((root / "claude-agent").exists())

    def test_delayed_old_session_events_cannot_overwrite_a_fork(self):
        self.invoke("SessionStart", session_id="session-a", source="startup")
        self.invoke("SessionStart", session_id="session-b", source="fork")
        self.invoke("UserPromptSubmit", session_id="session-b")
        for event in ("SessionEnd", "SubagentStart", "SubagentStop", "Stop", "PreCompact"):
            with self.subTest(event=event):
                calls = self.invoke(event, session_id="session-a", agent_id="old-agent")
                self.assertFalse([c for c in calls if c[0] != "getmeta"], calls)
                meta = json.loads(self.state.read_text())
                self.assertEqual(meta["codex:resume"], "session-b")
                self.assertEqual(meta["tab:flagcolor"], "#4a9eff")
        self.assert_color(self.invoke("Stop", session_id="session-b"), "#58c142")
        self.invoke("SessionEnd", session_id="session-b")
        calls = self.invoke("SubagentStart", session_id="session-b", agent_id="late-agent")
        self.assertFalse([c for c in calls if c[0] != "getmeta"], calls)

    def test_session_ownership_check_and_writes_are_serialized(self):
        barrier = Path(self.tmp.name) / "barrier"
        barrier.mkdir()
        env = dict(self.env, WSH_READ_BARRIER=str(barrier))
        processes = []
        try:
            old = subprocess.Popen(["/bin/zsh", str(SPOON / "wave-codex-hook.sh"), "PreCompact"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=env)
            processes.append(old)
            old.stdin.write(json.dumps({"session_id": "codex-session"}))
            old.stdin.close()
            old.stdin = None
            deadline = time.monotonic() + 2
            while not (barrier / "ready").exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue((barrier / "ready").exists())
            new = subprocess.Popen(["/bin/zsh", str(SPOON / "wave-codex-hook.sh"), "SessionStart"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=self.env)
            processes.append(new)
            new.stdin.write(json.dumps({"session_id": "new-session", "source": "fork"}))
            new.stdin.close()
            new.stdin = None
            try:
                new.wait(timeout=.4)
            except subprocess.TimeoutExpired:
                pass
            (barrier / "release").touch()
            for process in processes:
                _, stderr = process.communicate(timeout=4)
                self.assertEqual(process.returncode, 0, stderr)
            meta = json.loads(self.state.read_text())
            self.assertEqual(meta["codex:resume"], "new-session")
            self.assertEqual(meta["tab:flagcolor"], "#58c142")
        finally:
            (barrier / "release").touch()
            for process in processes:
                if process.poll() is None:
                    process.kill()
                process.communicate()

    def test_session_start_records_effective_codex_home(self):
        self.env["CODEX_HOME"] = str(Path(self.tmp.name) / "account B")
        self.invoke("SessionStart", source="startup")
        meta = json.loads(self.state.read_text())
        self.assertEqual(Path(meta["codex:home"]).resolve(), Path(self.env["CODEX_HOME"]).resolve())

    def test_permissions_and_questions_are_gold_with_codex_title(self):
        for event, tool in [("PermissionRequest", "Bash"),
                            ("PreToolUse", "request_user_input"),
                            ("PreToolUse", "functions.request_user_input")]:
            with self.subTest(event=event, tool=tool):
                calls = self.invoke(event, tool_name=tool)
                self.assert_color(calls, "#e0b956")
                self.assertTrue(any(c[0] == "notify" and "Codex" in c for c in calls), calls)


class CodexInstallTests(unittest.TestCase):
    def test_merge_preserves_other_hooks_migrates_old_entries_and_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="wave codex ") as tmp:
            path = Path(tmp) / "hooks.json"
            old = str(Path(tmp) / "wave-claude-hook.sh")
            new = str(Path(tmp) / "wave-codex-hook.sh")
            unrelated = {"type": "command", "command": "my-existing-hook", "timeout": 11}
            path.write_text(json.dumps({"description": "keep", "hooks": {
                "Stop": [{"hooks": [unrelated, {"type": "command", "command": shlex.quote(old) + " Stop"}]}],
                "PreToolUse": [{"matcher": "AskUserQuestion", "hooks": [{"type": "command", "command": shlex.quote(old) + " Question"}]}]}}))
            cmd = ["python3", str(SPOON / "install-codex-hooks.py"), str(path), new]
            for _ in range(2):
                r = subprocess.run(cmd, capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
            config = json.loads(path.read_text())
            self.assertEqual(config["description"], "keep")
            self.assertIn(unrelated, config["hooks"]["Stop"][0]["hooks"])
            for event in ("SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
                          "PermissionRequest", "PostToolUse", "Stop", "Interrupt",
                          "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"):
                commands = [h["command"] for g in config["hooks"][event] for h in g["hooks"]]
                self.assertEqual(commands.count(shlex.quote(new) + " " + event), 1, commands)
                self.assertFalse(any("wave-claude-hook.sh" in c for c in commands))
            self.assertTrue(list(Path(tmp).glob("hooks.json.bak.*")))

    def test_installer_deploys_and_configures_both_agents_once(self):
        with tempfile.TemporaryDirectory(prefix="wave install ") as tmp:
            root = Path(tmp)
            (root / "bin").mkdir()
            for name in ("hs", "codex"):
                stub = root / "bin" / name
                stub.write_text("#!/bin/sh\nexit 0\n")
                stub.chmod(0o755)
            codex_dir = root / "custom codex home"
            codex_dir.mkdir()
            (root / ".claude").mkdir()
            (root / ".claude/settings.json").write_text('{"model":"keep"}')
            (root / ".zshrc").write_text("# unrelated configuration\n")
            env = dict(os.environ, HOME=str(root), CODEX_HOME=str(codex_dir),
                       PATH=str(root / "bin") + ":" + os.environ["PATH"])
            installer = SPOON.parent / "install.sh"
            for _ in range(2):
                r = subprocess.run(["sh", str(installer)], cwd=SPOON.parent,
                                   env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(r.returncode, 0, r.stderr)
            deployed = root / ".hammerspoon/Spoons/WaveSwitcher.spoon"
            self.assertTrue((deployed / "wave-codex-hook.sh").exists())
            self.assertTrue((deployed / "codex-resume.zsh").exists())
            hooks = json.loads((codex_dir / "hooks.json").read_text())["hooks"]
            self.assertEqual(len(hooks), 12)
            self.assertTrue(all(len(groups) == 1 for groups in hooks.values()))
            self.assertIn(str(deployed / "wave-codex-hook.sh"), shlex.split(hooks["Stop"][0]["hooks"][0]["command"]))
            rc = (root / ".zshrc").read_text()
            self.assertEqual(rc.count("source "), 1)
            self.assertTrue(rc.startswith("# unrelated configuration\n"))
            self.assertEqual(json.loads((root / ".claude/settings.json").read_text())["model"], "keep")

    def test_skip_flags_do_not_configure_either_agent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".codex").mkdir()
            (root / ".claude").mkdir()
            (root / ".zshrc").write_text("untouched")
            env = dict(os.environ, HOME=tmp, CODEX_HOME=str(root / ".codex"),
                       PATH="/usr/bin:/bin")
            r = subprocess.run(["sh", str(SPOON.parent / "install.sh"), "--no-claude", "--no-codex"],
                               cwd=SPOON.parent, env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertFalse((root / ".codex/hooks.json").exists())
            self.assertFalse((root / ".claude/settings.json").exists())
            self.assertEqual((root / ".zshrc").read_text(), "untouched")

    def test_malformed_hooks_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "hooks.json"
            path.write_text("{broken")
            r = subprocess.run(["python3", str(SPOON / "install-codex-hooks.py"), str(path), "/tmp/hook"], capture_output=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(path.read_text(), "{broken")


class CodexResumeTests(unittest.TestCase):
    def test_resume_restores_a_session_specific_codex_home(self):
        with tempfile.TemporaryDirectory(prefix="wave account ") as tmp:
            root = Path(tmp)
            binpath = root / "bin"
            binpath.mkdir()
            saved_home = root / "account B"
            saved_home.mkdir()
            log = root / "codex-home.txt"
            wsh = root / "Library/Application Support/waveterm/bin/wsh"
            wsh.parent.mkdir(parents=True)
            wsh.write_text(f"#!{sys.executable}\nimport sys\nif sys.argv[1]=='getmeta': print({str(saved_home)!r} if sys.argv[-1]=='codex:home' else 'saved-session')\n")
            wsh.chmod(0o755)
            codex = binpath / "codex"
            codex.write_text(f"#!{sys.executable}\nimport os, pathlib\npathlib.Path({str(log)!r}).write_text(os.environ.get('CODEX_HOME', '<unset>'))\n")
            codex.chmod(0o755)
            env = dict(os.environ, HOME=tmp, PATH=str(binpath)+":/usr/bin:/bin", WAVETERM_BLOCKID="block")
            env.pop("CODEX_HOME", None)
            env.pop("WAVESWITCHER_CODEX_RESUMED", None)
            subprocess.run(["/bin/zsh", "-dfi", "-c", 'source "$1"', "test", str(SPOON / "codex-resume.zsh")],
                           env=env, capture_output=True, check=True, timeout=5)
            self.assertEqual(log.read_text(), str(saved_home))

    def test_resume_uses_codex_and_consumes_the_marker_once(self):
        with tempfile.TemporaryDirectory(prefix="wave resume ") as tmp:
            root = Path(tmp)
            binpath = root / "bin"
            binpath.mkdir()
            log = root / "calls.jsonl"
            wsh = root / "Library/Application Support/waveterm/bin/wsh"
            wsh.parent.mkdir(parents=True)
            wsh.write_text(f"#!{sys.executable}\nimport json,os,sys\nwith open(os.environ['RESUME_LOG'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\nif sys.argv[1]=='getmeta': print('saved-codex-session' if sys.argv[-1]=='codex:resume' else '')\n")
            wsh.chmod(0o755)
            codex = binpath / "codex"
            codex.write_text(f"#!{sys.executable}\nimport json,os,sys\nwith open(os.environ['RESUME_LOG'],'a') as f: f.write(json.dumps(['codex']+sys.argv[1:])+'\\n')\n")
            codex.chmod(0o755)
            env = dict(os.environ, HOME=tmp, PATH=str(binpath)+":/usr/bin:/bin",
                       WAVETERM_BLOCKID="block", RESUME_LOG=str(log))
            env.pop("WAVESWITCHER_CODEX_RESUMED", None)
            command = 'source "$1"; source "$1"'
            r = subprocess.run(["/bin/zsh", "-dfi", "-c", command, "test", str(SPOON / "codex-resume.zsh")],
                               capture_output=True, text=True, env=env, timeout=5)
            self.assertEqual(r.returncode, 0, r.stderr)
            calls = [json.loads(s) for s in log.read_text().splitlines()]
            self.assertEqual(calls, [["getmeta", "-b", "this", "--raw", "codex:resume"],
                                     ["getmeta", "-b", "this", "--raw", "codex:home"],
                                     ["setmeta", "-b", "this", "codex:resume=", "codex:home="],
                                     ["codex", "resume", "saved-codex-session"]])
            log.unlink()
            subprocess.run(["/bin/zsh", "-df", "-c", command, "test", str(SPOON / "codex-resume.zsh")],
                           capture_output=True, env=env, timeout=5, check=True)
            self.assertFalse(log.exists(), "Tool shells must not auto-resume Codex")


if __name__ == "__main__":
    unittest.main()
