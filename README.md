# sidekick-verifiers

Curated catalog of community verifiers for [Sidekick](https://github.com/meloniteai/sidekick).
The in-TUI **Browse Verifiers** modal (Ctrl+P → Browse Verifiers) reads this
repo directly and installs entries into either a project `hud.yaml` or the
global `~/.hud/hud.yaml` with one keystroke.

## Layout

```
<type>/<slug>/manifest.yaml   # discovered by the browser
<type>/<slug>/<artefact>      # the SKILL.md or script the manifest pins
```

`<type>` is one of `agent`, `command`, `binary`. `<slug>` is the directory
name (used as the default verifier name on install if `manifest.yaml`
doesn't set one explicitly).

## Manifest schema

```yaml
name: <human-readable name>          # default verifier name on install
type: agent | command | binary       # must match the parent directory
description: |
  Short paragraph shown in the detail pane of the browser.
direction: N | NE | E | SE | S | SW | W | NW   # default slot on the compass
default_timeout: 60s                 # optional, overrides the runtime default
artefact: <filename>                 # file in this dir; fetched on install
sha256: <hex>                        # of the artefact bytes; integrity pin

# agent-only
agent:
  agent: claude | codex
  model: <model id>
  thinking: low | medium | high

# optional; allowed_tools is appended to the hardcoded Claude baseline
permissions:
  network: false
  filesystem: read-only
  env: []
  allowed_tools:
    - "Bash(go test:*)"
```

Compute `sha256` with `shasum -a 256 <artefact>` — HUD refuses to fetch any
artefact whose bytes drift from the pin.

## Contributing

1. Add a directory under the matching type, drop in `manifest.yaml` and
   the artefact.
2. Run `shasum -a 256 <type>/<slug>/<artefact>` and paste the hex into the
   manifest.
3. Open a PR.

The browser tolerates malformed manifests (skipped silently with a logged
warning), so a bad entry won't blank the catalog for other users — but it
will hide your verifier until fixed.
