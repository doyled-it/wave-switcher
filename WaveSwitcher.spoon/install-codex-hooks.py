#!/usr/bin/env python3
"""Merge WaveSwitcher hooks without disturbing unrelated Codex configuration."""
import copy
import json
from pathlib import Path
import shlex
import shutil
import sys
import time


EVENTS = ("SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
          "PermissionRequest", "PostToolUse", "Stop", "Interrupt",
          "SubagentStart", "SubagentStop", "PreCompact", "PostCompact")


def install(path, hook):
    config = json.loads(path.read_text()) if path.exists() else {}
    original = copy.deepcopy(config)
    if not isinstance(config, dict) or not isinstance(config.get("hooks", {}), dict):
        raise ValueError("Expected an object with a hooks object")
    hooks = config.setdefault("hooks", {})
    managed_paths = {str(hook), str(hook.with_name("wave-claude-hook.sh"))}

    def managed(handler):
        try:
            command = shlex.split(handler.get("command", ""))
        except ValueError:
            return False
        return bool(command) and command[0] in managed_paths

    for event, groups in list(hooks.items()):
        if not isinstance(groups, list):
            raise ValueError(f"Expected a list of matcher groups for {event}")
        kept = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError(f"Invalid matcher group for {event}")
            group["hooks"] = [h for h in group["hooks"] if not managed(h)]
            if group["hooks"]:
                kept.append(group)
        hooks[event] = kept
    for event in EVENTS:
        hooks.setdefault(event, []).append({"hooks": [{
            "type": "command", "command": shlex.quote(str(hook)) + " " + event,
            "timeout": 3 if event in ("Interrupt", "SessionEnd") else 5,
        }]})
    if config == original:
        print(f"Codex hooks already configured in {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        shutil.copy2(path, str(path) + f".bak.{time.time_ns()}")
    temp = path.with_name(path.name + ".waveswitcher.tmp")
    try:
        temp.write_text(json.dumps(config, indent=2) + "\n")
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)
    print(f"Installed Codex hooks in {path}; review and trust them with /hooks in Codex.")


if __name__ == "__main__":
    try:
        install(Path(sys.argv[1]), Path(sys.argv[2]))
    except (ValueError, TypeError, AttributeError, OSError) as exc:
        sys.exit(f"Codex hooks left unchanged: {exc}")
