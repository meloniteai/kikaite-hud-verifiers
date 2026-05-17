#!/usr/bin/env bash
# gofmt-check: reports gofmt cleanliness of the session worktree as a
# HUD command verifier. Reads {session_worktree, session_base_ref, ...}
# on stdin and writes {"distance":0|1,"reason":"…"} on stdout.
#
# Distance 0 = clean. Distance 1 = at least one .go file is unformatted.
# Anything else is treated as a hard error by the verifier runner.
set -eu

# Pull session_worktree out of stdin without needing jq. We rely on the
# field being a JSON string immediately after the key; this is a tight
# coupling on the verifier.Session shape but avoids a runtime dep on jq.
session_json="$(cat)"
worktree="$(printf '%s' "$session_json" \
  | sed -n 's/.*"session_worktree"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [ -z "$worktree" ]; then
  worktree="$(pwd)"
fi

if ! command -v gofmt >/dev/null 2>&1; then
  printf '{"distance":0,"reason":"gofmt not installed; skipping"}\n'
  exit 0
fi

bad="$(gofmt -l "$worktree" 2>/dev/null | head -n 5 || true)"
if [ -z "$bad" ]; then
  printf '{"distance":0,"reason":"all .go files are gofmt-clean"}\n'
  exit 0
fi

# Trim each path to the basename for readability in the compass tooltip.
names="$(printf '%s\n' "$bad" | awk -F/ '{print $NF}' | paste -sd, -)"
printf '{"distance":1,"reason":"unformatted: %s"}\n' "$names"
