"""Exercise the real adapters/installers with Wave's external CLI stubbed."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

SPOON = Path(__file__).resolve().parents[1] / "WaveSwitcher.spoon"


class CodexHookTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        (root / "bin").mkdir()
        self.log = root / "wsh.jsonl"
        wsh = root / "bin/wsh"
        wsh.write_text("#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ['WSH_LOG'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n")
        wsh.chmod(0o755)
        self.env = dict(os.environ, TMPDIR=str(root), WSH_LOG=str(self.log),
                        PATH=str(root / "bin") + ":/usr/bin:/bin",
                        WAVETERM_TABID="test-tab", WAVETERM_BLOCKID="test-block")
        self.env.pop("WSW_DEBUG", None)
        self.env.pop("WSW_AGENT", None)

    def invoke(self, event, **extra):
        payload = dict(session_id="codex-session", hook_event_name=event,
                       cwd="/tmp/demo", model="demo", permission_mode="default",
                       transcript_path=None, **extra)
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
        self.assertIn(["setmeta", "-b", "this", "codex:resume="], calls)

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
    def test_resume_uses_codex_and_consumes_the_marker_once(self):
        with tempfile.TemporaryDirectory(prefix="wave resume ") as tmp:
            root = Path(tmp)
            binpath = root / "bin"
            binpath.mkdir()
            log = root / "calls.jsonl"
            wsh = root / "Library/Application Support/waveterm/bin/wsh"
            wsh.parent.mkdir(parents=True)
            wsh.write_text(f"#!{sys.executable}\nimport json,os,sys\nwith open(os.environ['RESUME_LOG'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\nif sys.argv[1]=='getmeta': print('saved-codex-session')\n")
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
                                     ["setmeta", "-b", "this", "codex:resume="],
                                     ["codex", "resume", "saved-codex-session"]])
            log.unlink()
            subprocess.run(["/bin/zsh", "-df", "-c", command, "test", str(SPOON / "codex-resume.zsh")],
                           capture_output=True, env=env, timeout=5, check=True)
            self.assertFalse(log.exists(), "Tool shells must not auto-resume Codex")


if __name__ == "__main__":
    unittest.main()
