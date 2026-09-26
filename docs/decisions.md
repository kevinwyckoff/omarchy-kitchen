# Decisions

Newest first. Each entry says what was decided, why, and what would change it. When a decision changes, add a new entry that supersedes the old one rather than editing history.

## 2026-09-25: Phase 0 shape

**Decision.**
- **Encryption gets its own screen**, after the install mode and right before the wipe summary, on every path (full disk, free space, deferred provisioning). The spec's "row on the Omakase summary" doesn't fit: the account summary comes before disk selection, and the other two paths never show it. The spec (§3.1) now says this.
- **The §5.4 manual change moves to Phase 2.** Its text names `omarchy secureboot enable`, which won't exist until then. Phase 0 is `omarchy-iso` only.
- **Two topic branches, both from `quattro`:** `wipe-summary` (§2, §2.3) and `visible-encryption` (§3), stacked on it. They're smaller to review and to rebase against the open upstream PRs that also touch the configurator (for example #122, #140 and #155).
- **"Is this install encrypted?" comes from the install JSON**, not `user_encrypt_installation.txt`: `disk_encryption` for full disk, `storage.luks_uuid` for pre-mounted. The flag only decides for a pre-mounted config with no `luks_uuid`, and a disagreement is logged. The spec (§3.2) now says this.
- **Testing on WSL:** fixture-driven unit tests, a root-only probe test on loop devices, and QEMU runs driven by keystrokes and screenshots sent through QEMU's control socket (QMP), instead of `omarchy-iso-test` (which needs an Omarchy host).

**What would change it.** An upstream design for the same screens: we'd rebase onto theirs rather than carry ours.

## Findings, 2026-09-25: Phase 0 on a test ISO

- **Rows A–D pass** on an ISO built from `visible-encryption` plus the #196 build fix, with two identical `Samsung SSD 980 PRO` drives (one Windows-like, one blank) and an invalid cidata drive attached:
  - **A:** the picker tells the drives apart by serial and contents. The summary lists the four Windows partitions with live probe results ("EFI boot files · Windows Boot Manager", "Windows · ~1.5 GiB used"). Erasing needs the name typed; a wrong name is refused, and Esc goes back.
  - **B:** the blank drive gets a plain Yes/No.
  - **C:** the cidata drive is never offered, and it is listed as "cidata drive" under "Not touched".
  - **D:** an unencrypted install passes `validate_boot`, boots with no LUKS prompt to the SDDM login screen, has btrfs directly on the partition, no `cryptdevice=` and no `autologin.conf`.
- **Busy partitions** work end to end: a partition mounted from tty2 shows in red, "Release them" unmounts it through `omarchy-iso-cleanup-disk`, and the summary re-probes.
- **Probes are read-only.** The loop-device test hashes every partition before and after probing.
- **Free-space path** works on the ISO. On an 80 GiB drive with the Windows layout and 40 GiB unallocated, the summary says "Nothing is erased", lists the four Windows partitions as kept, and confirms with a plain Yes/No. The encrypted install passes `validate_boot`. `qemu-img map` on the overlay shows that the install wrote only to the primary GPT header, the free region and the backup GPT: nothing inside the Windows partitions.
- **Not covered on the ISO:** the laptop hint, because QEMU reports a desktop chassis.
- **Upstream quirk:** with an invalid `CIDATA` drive attached, the live ISO's cloud-init prints its logs over the wizard on tty1. That isn't Phase 0's doing, but it makes row C's screen messy.
- **gum 2.0.2** returns 1 for Esc and 130 for Ctrl+C in `input`, `confirm` and `choose`. `gum input` panics in a 0×0 pty, which only matters for test harnesses.
- **Hyprland 0.56 uses a Lua config**, so `hyprctl keyword` is gone. Use `hyprctl eval 'hl.monitor({ … })'`.

## 2026-09-25: Follow arch-mact2's T2 firmware rename, and accept its missing-firmware gap for now

**Decision.** `omarchy` carries commit `b0b3561` ("Install the renamed T2 Broadcom firmware fetcher") on `kitchen`, from the topic branch `t2-bcm-firmware-fetcher`, which starts at `quattro` so it can go upstream as-is. It renames `apple-bcm-firmware` to `apple-bcm-firmware-fetcher` in `install/hardware/apple/fix-t2.sh` and `install/omarchy-other.packages`, and adds a regression check to `test/shell.d/t2-hardware-test.sh`. No migration: existing installs keep the old package and its firmware files. Local ISO builds use upstream's open fix omacom/omarchy-iso#196, cherry-picked onto the local-only branch `build/pr-196` in `omarchy-iso`.

**Why.** arch-mact2 dropped `apple-bcm-firmware` on 2026-09-16. The replacement only conflicts with the old name and doesn't replace it, so pacman can't follow the rename. Every ISO build (upstream's nightly included) fails with "target not found", and so would every T2 install.

**The gap.** The fetcher ships no firmware. At install time it copies the Wi-Fi and Bluetooth firmware from the macOS APFS volume on `nvme0n1`. The installer's default wipes the whole disk, so a T2 Mac installed that way comes up without Wi-Fi or Bluetooth. The install doesn't fail and gives only a quiet warning. This bears on the spec's wipe summary: wiping macOS on a T2 Mac also loses this firmware, and the summary should say so.

**What would change it.** Upstream merging #196 (drop `build/pr-196`) or an equivalent of `b0b3561` (the next sync drops ours). arch-mact2 shipping bundled firmware again, or Omarchy adopting another firmware method from the t2linux wiki, would close the gap.

## Findings, 2026-09-25: first local ISO build and install

- **Building on WSL works.** `omarchy-iso-make` does all its work in a privileged `archlinux/archlinux` container, so an Ubuntu WSL2 host with Docker can build without Arch tools. Use `--keep-pkg-cache --no-boot-offer` there: the first skips a `sudo rm` of a pacman cache Ubuntu doesn't have, the second skips `gum`. `bin/omarchy-iso-boot` and `bin/omarchy-iso-test` only run on an Omarchy host (they call `omarchy-pkg-add` and hardcode Arch's firmware paths), so on WSL, QEMU was run by hand with Ubuntu's `/usr/share/OVMF/OVMF_CODE_4M.fd`.
- **A `--local-source` build installs the local code.** The ISO targets `omarchy-dev` and `omarchy-settings-dev` built from the sibling checkouts. The published `omarchy` and `omarchy-settings` also land in the offline mirror, because `elsewhen` depends on `omarchy`, but the install doesn't use them. An encrypted install in QEMU took 1m33s and booted to Hyprland with no failed units.
- **Installer behaviour the spec targets, seen on `quattro`.** Encryption is on by default, and the only way to opt out is a grey hint on the final confirm screen ("Press Ctrl+C for unencrypted install"). The wipe confirmation says only "Everything will be overwritten", with nothing about what's on the disk. The disk picker labels a virtio disk `/dev/vda (40G) - 0x1af4`, a raw vendor ID rather than a model name.

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
