# Omarchy: The Kitchen Is Open

This repo holds the plans and workspace tooling for a fork of Omarchy. The code lives in sibling checkouts, not here. See `README.md` for the layout.

# Where things go

- `plans/`: the spec. `plans/kitchen-installer-spec.md` is the current plan and the source of truth for what gets built. `plans/kitchen-installer-spec-v1-full.md` is the full original design, kept as reference for deferred work; don't edit it.
- `docs/decisions.md`: decisions and findings, newest first. Add an entry when a decision is made or changes; don't rewrite old entries.
- `docs/workflow.md`: branches, syncing with upstream, upstreaming.
- `scripts/`: workspace setup and upstream sync.

# Working in the forks

- `../omarchy` and `../omarchy-iso` are forks. Work on topic branches and merge them into `kitchen` with a rebase. Never commit to `quattro`; it mirrors upstream.
- Each fork has its own `AGENTS.md` and `agents/skills/` guides from upstream. Follow them when working there.
- `../omarchy-pkgs` is a read-only upstream clone for ISO builds. Don't commit to it.

# Style

Same as upstream Omarchy:

- Shell scripts use `#!/bin/bash`, two-space indentation, `[[ ]]` for string and file tests, `(( ))` for numeric tests. In `[[ ]]`, don't quote variables, but do quote string literals.
- Markdown uses full lines with no hard wrapping; break only at structural boundaries like headings and list items.
