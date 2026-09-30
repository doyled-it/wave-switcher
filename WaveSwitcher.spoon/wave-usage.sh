#!/bin/zsh
# Fetch Claude Code subscription usage (the numbers behind /usage) from the OAuth
# usage endpoint and print a compact JSON object:
#   {
#     "session": {"util":<pct>,"resets":"<iso>","sev":"normal|warning|critical"} | null,
#     "week":    {"util":<pct>,"resets":"<iso>","sev":...} | null,
#     "opus":    {"util":<pct>,"resets":"<iso>"} | null,
#     "sonnet":  {"util":<pct>,"resets":"<iso>"} | null,
#     "credits": {"util":<pct>,"used":<n>} | null
#   }
#
# The access token is read from the macOS Keychain (Claude Code's own credential)
# and sent ONLY to api.anthropic.com. Results cached 60s. Prints "{}" on failure.
#
# The anthropic-beta + User-Agent headers matter: without a claude-code User-Agent
# the endpoint routes you to an aggressively rate-limited bucket (429s).

CACHE="${TMPDIR:-/tmp}/waveswitcher-usage.json"
TTL=60
UA="claude-code/2.1.0"

if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
  if [ "$age" -ge 0 ] && [ "$age" -lt "$TTL" ]; then cat "$CACHE"; exit 0; fi
fi

TOKEN="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null)"
[ -z "$TOKEN" ] && { echo '{}'; exit 0; }

resp="$(curl -s --max-time 5 https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "User-Agent: $UA" \
  -H "Content-Type: application/json" 2>/dev/null)"

out="$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("{}"); sys.exit()
def sev_of(kind):
    for L in (d.get("limits") or []):
        if L.get("kind") == kind:
            return L.get("severity")
    return None
def bucket(top, kind):
    b = d.get(top) or {}
    u = b.get("utilization")
    if u is None: return None
    return {"util": u, "resets": b.get("resets_at"), "sev": sev_of(kind)}
def simple(top):
    b = d.get(top) or {}
    u = b.get("utilization")
    if u is None: return None
    return {"util": u, "resets": b.get("resets_at")}
ex = d.get("extra_usage") or {}
credits = {"util": ex.get("utilization"), "used": ex.get("used_credits")} if ex.get("is_enabled") else None
print(json.dumps({
    "session": bucket("five_hour", "session"),
    "week":    bucket("seven_day", "weekly_all"),
    "opus":    simple("seven_day_opus"),
    "sonnet":  simple("seven_day_sonnet"),
    "credits": credits,
}))
' 2>/dev/null)"

[ -z "$out" ] && out='{}'
printf '%s' "$out" > "$CACHE" 2>/dev/null
printf '%s' "$out"
