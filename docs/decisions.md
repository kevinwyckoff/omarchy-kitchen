# Decisions

Newest first. Each entry says what was decided, why, and what would change it. When a decision changes, add a new entry that supersedes the old one rather than editing history.

## 2026-09-25: Repository layout and upstream tracking

**Decision.** Two real GitHub forks (`omarchy`, `omarchy-iso`) plus this umbrella repo. No monorepo, no submodules.

**Why.**
- The spec touches both upstream repos. A single repo can't be a GitHub fork of two upstreams.
- Real forks keep rebasing on upstream a one-command job, and let Phase 0 and 1 changes go upstream as ordinary PRs (spec §8, question 4).
- Submodules pin commits, which fights a workflow that rebases regularly. Sibling checkouts are also exactly what upstream's `omarchy-iso-make --local-source` expects.

**What would change it.** Deciding never to rebase on upstream again (a hard fork). Then a monorepo would be simpler.

## 2026-09-25: Track `quattro`

**Decision.** Both forks track upstream's `quattro` branch. The fork's own `quattro` is an untouched mirror; our work lives on `kitchen`, which is the forks' default branch.

**Why.** `quattro` is the default branch of both `omacom/omarchy` and `omacom/omarchy-iso` (Omarchy 4.0.0.alpha), and it's what the spec was written against. `omarchy` also has `dev` and `rc`; `omarchy-iso` also has `main`. Revisit when upstream moves its default branch after 4.0 ships.

## 2026-09-25: `omarchy-pkgs` is cloned, not forked

**Decision.** Clone `omacom/omarchy-pkgs` read-only as a sibling. Fork it only when a change needs a package that upstream doesn't ship.

**Why.** Local ISO builds need it (`--local-source <omarchy> <pkgs>`), but nothing in the current spec changes packages. `sbctl` is already in the Arch repos.

## 2026-09-25: Follow upstream conventions everywhere

**Decision.** Use upstream's style rules (from `omarchy/AGENTS.md`) in all three repos, including scripts in this one: `#!/bin/bash`, two-space indent, `[[ ]]` and `(( ))`, full-line markdown without hard wrapping.

**Why.** Code that looks like upstream is easier to rebase and easier to send upstream.

## 2026-09-25: Umbrella repo renamed to `omarchy-kitchen`

**Decision.** Rename `Omarchy-The-Kitchen-is-Open-` to `omarchy-kitchen` before anyone clones it. The product name stays "Omarchy: The Kitchen Is Open".

**Why.** The trailing hyphen came from the quotes in the name, and renames get more expensive once there are clones and links. GitHub redirects the old URL either way.

**Not decided here.** The installer CLI name (spec §8, question 5).

## Findings, 2026-09-25

- **Spec paths verified.** Every upstream file the v2 spec cites exists on `quattro` today: `configs/airootfs/root/configurator`, `…/root/.automated_script.sh`, `…/usr/local/bin/omarchy-cidata-load`, `…/orchestrator/phases_impl.py`, `configs/profiledef.sh`, `bin/omarchy-iso-test`, and in `omarchy`: `bin/omarchy-hibernation-setup`, `manual/02-getting-started.md`, `manual/44-mac-support.md`, `manual/51-unattended-installs.md`. Line numbers were not rechecked.
- **Licenses.** `omarchy` is MIT (copyright David Heinemeier Hansson). `omarchy-iso` is MIT (copyright 2026 Anton Hvornum).
- **Spec §8, question 3 (vendor vs write), partly answered.** `peregrinus879/omarchy-secureboot` is now called OmaSecBoot. It's MIT-licensed, so vendoring with attribution is allowed. It was last committed to on 2026-09-23 and has CI, upstream-contract tests for sbctl and Limine, and a PKGBUILD. Its 0.1.0 release has a hardware record on one machine only (an ASUS Vivobook with Windows device encryption alongside). Still open: whether to depend on it as a package, vendor it, or write our own.
