#!/bin/zsh
# Fetch Claude Code subscription usage (the same numbers as /usage) from the
# OAuth usage endpoint and print a compact JSON line:
#   {"session":<pct>,"sessionResets":"<iso>","week":<pct>,"weekResets":"<iso>"}
#
# The access token is read from the macOS Keychain (Claude Code's own credential)
# and sent ONLY to api.anthropic.com. Results are cached for 60s to avoid
# hammering the endpoint every time the picker opens.
#
# Requires: security (macOS), curl, python3. Prints "{}" on any failure.

CACHE="${TMPDIR:-/tmp}/waveswitcher-usage.json"
TTL=60

if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
  if [ "$age" -ge 0 ] && [ "$age" -lt "$TTL" ]; then cat "$CACHE"; exit 0; fi
fi

TOKEN="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null)"
[ -z "$TOKEN" ] && { echo '{}'; exit 0; }

resp="$(curl -s --max-time 5 https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null)"

out="$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("{}"); sys.exit()
fh = d.get("five_hour") or {}
sd = d.get("seven_day") or {}
print(json.dumps({
    "session": fh.get("utilization"),
    "sessionResets": fh.get("resets_at"),
    "week": sd.get("utilization"),
    "weekResets": sd.get("resets_at"),
}))
' 2>/dev/null)"

[ -z "$out" ] && out='{}'
printf '%s' "$out" > "$CACHE" 2>/dev/null
printf '%s' "$out"
