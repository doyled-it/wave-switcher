#!/bin/sh
# Read newline-separated working directories on stdin; emit a JSON array of
# { cwd, branch, worktree } for the ones that are git repos. Non-repos (e.g.
# multi-repo parent dirs) and blanks are skipped. Run async by the switcher so
# its ~per-repo git calls never block opening the Ctrl+K palette.
#
# Dependencies: git only.

jsonstr() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

printf '['
first=1
while IFS= read -r d; do
  [ -z "$d" ] && continue
  git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
  br="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -z "$br" ] && continue
  gd="$(git -C "$d" rev-parse --git-dir 2>/dev/null)"
  cgd="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)"
  wt=false
  [ -n "$gd" ] && [ "$gd" != "$cgd" ] && wt=true
  [ "$first" -eq 1 ] || printf ','
  first=0
  printf '{"cwd":%s,"branch":%s,"worktree":%s}' "$(jsonstr "$d")" "$(jsonstr "$br")" "$wt"
done
printf ']'
