# Contributing a verifier to the Sidekick registry

This repo is the community registry for Sidekick verifiers. Every
directory under `agent/`, `command/`, and `binary/` is one verifier:
a small rubric or script that scores how far a working tree is from
an agent's stated goal.

Pinning by sha256 is mandatory — every manifest in this repo declares
the hash of its artefact, and Sidekick refuses to load a body whose
hash drifted from the pin. The registry just makes verifiers
discoverable; the trust model is still per-artefact, per-hash.

To contribute, open a PR that adds a new directory with a
`manifest.yaml` and the artefact it points at.

---

## The protocol

A verifier is a process that the Sidekick daemon spawns once per
evaluation batch. There are three types:

| Type | I/O | When to use |
|---|---|---|
| `command` | stdin: session JSON · stdout: `{"distance", "reason", "status"}` JSON · exit 0 | Custom scoring logic. Most extensible. |
| `binary` | stdin: session JSON (may ignore) · stdout/stderr: free · exit code = score | Pass/fail wrappers around existing tools (`go test`, `eslint`). |
| `agent` | stdin: prompt body · stdout: agent CLI output (Sidekick parses) | Persona-style review with an LLM, driven by a `SKILL.md` rubric. |

### Session JSON (stdin for `command` and `binary`)

```json
{
  "goal": "ship the auth module",
  "session_base_ref": "abc123def...",
  "session_worktree": "/abs/path/to/anchored/worktree",
  "recent_diff": "diff --git a/... ...",
  "changed_files": ["src/auth.go", "src/auth_test.go"],
  "last_messages": ["user: ...", "assistant: ..."],
  "verifier_name": "MyVerifier"
}
```

Diff against `session_base_ref` from inside `session_worktree` to
score **cumulative session work**, not the last debounced write. For
shell verifiers without `jq`, see `command/gofmt-check/run.sh` for a
minimal `sed` extractor.

Drain stdin even if you don't need it (`cat >/dev/null`); otherwise
the parent's pipe write will eventually block.

### Score JSON (stdout for `command`)

Output one JSON object on a single line:

```json
{"distance": 0.42, "reason": "one short sentence", "status": "ok"}
```

- `distance` ∈ `[0.0, 1.0]` — clamped by Sidekick if you over/undershoot.
- `reason` is a single short sentence — the **most load-bearing**
  observation, not a summary.
- `status` is optional. If your verifier ran cleanly, omit it (Sidekick
  promotes to `"ok"`). If the verifier could not score this run
  (tooling missing, no diff to evaluate, prerequisite step pending),
  set `"status": "unknown"` and Sidekick will preserve the prior distance
  instead of pretending the score moved.

You may emit log lines on stderr (or even on stdout before your final
JSON line) — Sidekick is brace-aware and string-aware when extracting the
result, so trailing or leading prose is tolerated.

### Score anchors

To stay legible to agents, calibrate to one of:

- **0.00** — Goal fully satisfied (your dimension).
- **0.25** — Minor friction. Keep moving.
- **0.50** — A real concern. Address before next milestone.
- **0.75** — Blocking issue. Pivot now.
- **1.00** — Goal contradicted, or no diff at all.

Free-floating decimal scores ("0.37"/"0.42"/"0.61") drift between
runs and become noise. Stick to the anchors unless you have strong
evidence for something in between.

### Environment variables

- `SESSION_BASE_REF` — git SHA of `HEAD` when `sidekick start` began. Diff
  against this for cumulative session work, **not** against the last
  write.
- `SESSION_WORKTREE` — absolute path to the anchored worktree. Run
  `git -C $SESSION_WORKTREE ...` so the diff is rooted at the session,
  not at whatever directory the verifier was spawned from.
- `SIDEKICK_VERIFIER=1` — set automatically. Use this in your script if you
  call `claude` or `codex` and want to be sure Sidekick's hooks won't recurse
  on writes triggered by the verifier itself.

### Timeouts

Default 60s per verifier. Declare a per-verifier override with
`default_timeout` in your manifest:

```yaml
default_timeout: 120s
```

The subprocess receives a SIGTERM at the timeout, then SIGKILL shortly
after. Make sure your tool propagates signals (or wrap with `exec`).

---

## Registry layout

```
sidekick-verifiers/
├── agent/<name>/
│   ├── manifest.yaml
│   └── SKILL.md
├── command/<name>/
│   ├── manifest.yaml
│   └── run.sh
└── binary/<name>/
    ├── manifest.yaml
    └── run.sh
```

The directory name **is** the verifier id. Keep it short, kebab-case,
and descriptive of the dimension being scored (`no-storytelling`,
`gofmt-check`, `migration-safety`), not the implementation.

### `manifest.yaml`

Every verifier directory has a `manifest.yaml`. The shape:

```yaml
name: my-verifier              # must match the directory name
type: agent                    # agent | command | binary
description: |
  One paragraph. What does this verifier care about, and what does
  it ignore? Surfaced in registry listings — be concrete.
direction: NE                  # compass hint: N/NE/E/SE/S/SW/W/NW
default_timeout: 90s           # optional; default 60s
artefact: SKILL.md             # SKILL.md for agent, run.sh for command/binary
sha256: <64 hex chars>         # sha256 of the artefact file
agent:                         # only for type: agent
  agent: claude                # claude | codex
  model: claude-sonnet-4-6
  thinking: low
permissions:
  network: false
  filesystem: read-only        # read-only | read-write | none
```

Compute the artefact hash with `shasum -a 256 path/to/artefact` (or
`sha256sum` on Linux). The CI on this repo verifies the declared hash
matches the artefact bytes on every PR.

---

## Authoring a `command` verifier

A minimum viable shell verifier:

```bash
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null   # drain stdin

if ! command -v go >/dev/null; then
    printf '{"distance": 0.0, "reason": "go not on PATH", "status": "unknown"}\n'
    exit 0
fi

count=$(go build ./... 2>&1 | grep -c '^')
distance=$(awk -v c="$count" 'BEGIN { x = c / 10.0; if (x>1) x=1; printf "%.3f", x }')
printf '{"distance": %s, "reason": "%d build warnings"}\n' "$distance" "$count"
```

See [`command/gofmt-check/`](command/gofmt-check) for a reference
implementation that also extracts `session_worktree` from stdin
without a `jq` dependency.

---

## Authoring an `agent` verifier (SKILL.md)

A minimum viable rubric:

```markdown
---
name: my-verifier
description: One-line description shown in skill listings.
---

# my-verifier

You are the [Persona] reviewer for the Sidekick compass. Evaluate the
cumulative session work through [your specific lens], against the
agent's stated goal.

## How to evaluate

1. Use `$SESSION_WORKTREE` and `$SESSION_BASE_REF` from the runtime prompt.
2. Run `git -C $SESSION_WORKTREE diff $SESSION_BASE_REF --stat` to size the change.
3. Run `git -C $SESSION_WORKTREE diff $SESSION_BASE_REF` to read it.
4. Run `git -C $SESSION_WORKTREE status --porcelain` for untracked files.

## What you care about
- (positive criteria)

## What to penalize
- (negative criteria)

## Score anchors ([dimension])
- 0.00 — ...
- 0.25 — ...
- 0.50 — ...
- 0.75 — ...
- 1.00 — ...
```

Sidekick strips your YAML frontmatter, appends the runtime score-anchor
contract, and shells out to the configured agent CLI. The agent runs
with a tool allowlist of read-only git/file operations only.

See [`agent/no-storytelling/SKILL.md`](agent/no-storytelling/SKILL.md)
and [`agent/agents-md/SKILL.md`](agent/agents-md/SKILL.md) for full
rubrics.

---

## Submitting a verifier

1. Fork this repo.
2. Create `<type>/<name>/` (e.g. `agent/migration-safety/`).
3. Write the artefact (`SKILL.md` or `run.sh`). Make `run.sh`
   executable (`chmod +x`).
4. Compute its sha256: `shasum -a 256 <type>/<name>/<artefact>`.
5. Write `manifest.yaml` with the fields above. The `sha256` must
   match step 4 exactly.
6. Smoke-test locally (see below).
7. Open a PR. CI re-hashes the artefact and rejects drift.

Users install your verifier with:

```bash
sidekick verifier add https://raw.githubusercontent.com/meloniteai/sidekick-verifiers/main/agent/<name>/SKILL.md \
  --name <Name> --direction <Dir>
```

Or pin by hand in their `sidekick.yaml`:

```yaml
verifiers:
  - name: <Name>
    type: agent
    direction: NE
    source:
      url: https://raw.githubusercontent.com/meloniteai/sidekick-verifiers/main/agent/<name>/SKILL.md
      sha256: <64 hex chars>
```

If you ship a new version, open a new PR that updates the artefact
and the `sha256` in the same commit — never silently overwrite an
existing manifest's artefact, because pinned installs will refuse to
load a body whose hash drifted.

---

## Permissions

Declare what your verifier needs. Today these are surfaced in the TUI
on first run for trust-on-first-use; future versions will use them to
configure platform sandboxes.

```yaml
permissions:
  filesystem: read-only        # read-only | read-write | none
  network: false                # default false
  env: ["PATH", "HOME"]         # allowlist; everything else stripped
```

Be conservative. A verifier that doesn't need network shouldn't
declare it; users will trust your verifier more if its declared
surface matches what it actually does.

---

## Testing a verifier locally

```bash
# Smoke-test the JSON contract:
echo '{"goal":"x","session_worktree":"'"$PWD"'","session_base_ref":"HEAD","changed_files":["a.go"],"verifier_name":"Test"}' \
  | ./command/<name>/run.sh
# Expected: a single JSON line with distance, reason, optional status.

# Run inside Sidekick (point at the local artefact via a file:// source
# or symlink it into your project's sidekick.yaml):
sidekick start --headless &
echo '{"tool_input":{"file_path":"a.go"}}' | sidekick hook write
sidekick status   # see your verifier's distance/reason in the snapshot
```

---

## Common pitfalls

- **Forgetting to drain stdin.** Hangs the parent eventually.
- **Emitting JSON as a quoted string** (`echo "{...}"`). The shell may
  swallow the braces. Use `printf '{"distance": %s, ...}\n' "$x"`.
- **Computing distance from a single instance instead of cumulative
  work.** Diff against `$SESSION_BASE_REF` from `$SESSION_WORKTREE`,
  not against `HEAD~1` in `$PWD`.
- **Hard-coding paths.** Take paths from `$SESSION_WORKTREE` or
  arguments — Sidekick spawns verifiers from the directory it was
  started in, which is not always the project root.
- **Returning errors as distance=1.** That conflates "goal contradicted"
  with "tooling broken." Return `status: unknown` instead — Sidekick will
  preserve the prior distance and flag the row as not-yet-evaluable.
- **`sha256` drift in PRs.** Re-hash after every artefact edit;
  forgetting is the most common CI failure.
