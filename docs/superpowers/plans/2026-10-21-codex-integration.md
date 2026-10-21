# Codex CLI integration plan

Goal: Codex sessions launched in Wave use the existing picker, status colors,
notifications, activity timestamps, and restart resume alongside Claude Code.

Use a small Codex event adapter and reuse the existing status implementation.
Install into `${CODEX_HOME:-~/.codex}/hooks.json`, preserving unrelated hooks and
replacing only WaveSwitcher's old Claude commands in that Codex file. Keep hook
trust under Codex's `/hooks` control. Codex 0.163.0 does not document background
tasks in Stop; do not promise shell detection or Codex account usage.

- [x] Add failing behavioral tests for Codex events, resume identity, outside-Wave
  no-op, compaction preserving subagents, and hook installation/migration.
- [x] Implement adapter, shared provider identity, and Codex notification labels.
- [x] Add idempotent Codex hook installation and sourced Codex resume snippet;
  preserve existing Claude installation and skip flags.
- [x] Update README/AGENTS, run both suites, review diff, and deploy locally.

Verification: existing hook suite plus `python3 -m unittest discover -s tests`;
shell syntax, Lua compilation, and installed Codex config validation. Review
paths with spaces, malformed settings, existing mixed hook groups, disabled
integrations, and hooks executing outside Wave. No global trust bypass.

Result: 11 Python tests and 11 existing hook cases pass. Independent review found
no actionable defects and verified the download install path. Updated Spoon and
Codex hooks are installed locally; Hammerspoon loaded the Spoon and Codex reports
`config.load: ok`. Activation still requires the user's `/hooks` trust review.
