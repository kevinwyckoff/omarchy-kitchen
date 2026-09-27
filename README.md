# Omarchy: The Kitchen Is Open

A fork of [Omarchy](https://omarchy.org) that reworks the installer so it's more open: you can see what it's about to erase, choose whether to encrypt, describe an install in a text file, and keep Secure Boot on with keys your machine owns.

**Status:** All three phases are built and tested on the forks:

- Phase 0: the wipe summary and a visible encryption choice
- Phase 1: `install.toml` and `chefs-kitchen`
- Phase 2: `omarchy secureboot`, rows K–N in QEMU

The desktop hardware row passed on 2026-09-27 (Secure Boot enforcing on an ASRock board with a GTX 1650). The laptop row waits until a laptop is procured, and the upstream PRs wait for it. The current plan is [plans/kitchen-installer-spec.md](plans/kitchen-installer-spec.md).

## Repositories

The work spans two upstream repos, so the fork is two real GitHub forks plus this repo, which ties them together.

| Repo | Fork of | Holds |
|---|---|---|
| **omarchy-kitchen** (this repo) | none | Plans, decisions, workspace scripts |
| [omarchy-iso](https://github.com/kevinwyckoff/omarchy-iso) | [omacom/omarchy-iso](https://github.com/omacom/omarchy-iso) | The wizard, the `chefs-kitchen` CLI, the orchestrator (Phases 0 and 1) |
| [omarchy](https://github.com/kevinwyckoff/omarchy) | [omacom/omarchy](https://github.com/omacom/omarchy) | `omarchy secureboot` and the manual fixes (Phase 2) |

Both forks track upstream's `quattro` branch (Omarchy 4.0) and carry their changes on a branch called `kitchen`. See [docs/decisions.md](docs/decisions.md) for why it's laid out this way.

## Getting started

You need `git` and the GitHub CLI (`gh`), logged in.

```bash
mkdir -p ~/src/kitchen && cd ~/src/kitchen
git clone https://github.com/kevinwyckoff/omarchy-kitchen.git
./omarchy-kitchen/scripts/setup.sh
```

This clones every repo side by side, which is the layout upstream's ISO build expects:

```
~/src/kitchen/
  omarchy-kitchen/   this repo
  omarchy/           fork, branch kitchen
  omarchy-iso/       fork, branch kitchen
  omarchy-pkgs/      upstream clone, read-only (needed for local ISO builds)
```

Build an ISO from your checkouts:

```bash
cd ~/src/kitchen/omarchy-iso
./bin/omarchy-iso-make --local-source ../omarchy ../omarchy-pkgs
```

Until upstream merges [omacom/omarchy-iso#196](https://github.com/omacom/omarchy-iso/pull/196), build from a branch that has it cherry-picked (`build/pr-196` locally). Since 2026-09-16 the build otherwise fails with `target not found: apple-bcm-firmware`. On a host without Omarchy, such as Ubuntu under WSL, add `--keep-pkg-cache --no-boot-offer`: the build otherwise clears a pacman cache that isn't there with sudo, and offers to boot the ISO through gum.

Test in QEMU with the helpers in [scripts/qemu/](scripts/qemu/README.md), which cover keystrokes, screenshots, Secure Boot firmware setup and driving machines over SSH.

Keep up with upstream:

```bash
./omarchy-kitchen/scripts/sync-upstream.sh
```

## Documents

- [plans/kitchen-installer-spec.md](plans/kitchen-installer-spec.md): the current spec (v2, reduced scope)
- [plans/kitchen-installer-spec-v1-full.md](plans/kitchen-installer-spec-v1-full.md): the full original design, kept for the deferred parts (Custom screen, TPM2 unlock)
- [docs/decisions.md](docs/decisions.md): decisions and findings, newest first
- [docs/workflow.md](docs/workflow.md): branches, syncing with upstream, sending changes upstream

## License

MIT, like upstream. See [LICENSE](LICENSE). The forks keep upstream's own license files and copyright notices.
