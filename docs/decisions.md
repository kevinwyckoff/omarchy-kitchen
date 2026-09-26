# Decisions

Newest first. Each entry says what was decided, why, and what would change it. When a decision changes, add a new entry that supersedes the old one rather than editing history.

## 2026-09-26: Remote installs over SSH, on a private branch

**Decision.**
- **Opening SSH:** a USB or `cidata` drive carrying `live_authorized_keys` opens key-only root SSH on the live ISO. So does an ISO with that file at its root. Without the file, nothing changes.
- **Driving the install:** `omarchy-iso-remote install|wizard|follow` asks the questions (the wipe summary and confirmation, or the wizard) in the SSH session. The install then runs on tty1, where a dropped connection can't stop it. tty1 shows a notice meanwhile, so nobody starts a second install from the greeter.
- **Private branch:** this lives on the local `live-ssh` branch in omarchy-iso (e1bc754, 7ae213e, 6feeb7b), which is neither pushed nor merged into `kitchen`, at Kevin's request. Remote root access to an installer is a choice for this workspace, not a default for the public fork. `build/live-ssh` adds the #196 fix for local ISO builds.
- **One stick:** a personal ISO carries the public key at its root, remastered with `xorriso -boot_image any replay -map`. A second stick isn't needed, and Windows can't add a file to a flashed stick anyway.

**What would change it.** Wanting remote installs on the public fork, or upstream shipping an equivalent.

## Findings, 2026-09-26: first installs on real hardware

The machine: an ASRock B650M-HDV/M.2 (AMI BIOS 1.28), a Ryzen 7 7700X, a GTX 1650 and two NVMe drives. Everything was driven over SSH from the WSL workstation with `omarchy-iso-remote`.

- **Free-space install beside Windows 11:** the plan listed every Windows partition as kept, and they were. It took 1m54s.
- **Whole-disk install on the other NVMe drive:** the typed confirmation was answered with the device name. It took 1m57s. The first drive was cleared separately and became an encrypted data drive, with a key file on the encrypted root and the password as a second key slot.
- **`omarchy update -y` over SSH works:**
  - It needs `OMARCHY_PATH` set in the session. The security entrypoint refuses without it, before changing anything.
  - Each run answers about nine sudo prompts.
  - The kitchen build (r6638) stays installed, because edge's upstream `omarchy-dev` has a lower version number. The flip side is that the machine takes no upstream Omarchy changes until it's rebuilt from the fork.
- **For the forks:**
  - `ufw allow ssh` in the install chroot prints `ERROR: problem running`. It's harmless, because the rule lands in `user.rules`, which the installer checks. But it reads like a failure in the log. Candidate: silence it or explain it.
  - A fresh install has no pacman sync databases, because it was installed from the offline mirror. The first `omarchy-pkg-add` then fails with "target not found" until a full update runs. Candidate: sync on first boot, or have `omarchy-pkg-add` sync when the databases are missing.
  - NVMe device names differ between the live ISO and the installed system on this board. That confirms selecting disks by serial in `install.toml` was right.
  - systemd 262's NvPCR units fail on this AMD firmware TPM, leaving 3 failed units after every boot. It's cosmetic, but "0 failed units" checks fail on such hardware. It also bears on TPM2 unlock later.
  - The live greeter can draw before DHCP finishes, and then says "once this machine is on a network".
  - On this AMI firmware, `efibootmgr --bootnext` to a hand-made `HD(MBR)` entry for the stick was ignored. The firmware's own "UEFI: <stick>" entry works.
- **Next:** this machine fits the Phase 2 hardware row for a desktop with a discrete GPU (the GTX 1650's option ROM). Secure Boot hasn't been enabled on it yet.

## 2026-09-26: Phase 2 shape

**Decision.**
- **OmaSecBoot's design replaces the original §5.3.** It appends your keys to KEK and db, and the user deletes only the PK. It never fails an update: it repairs, or warns. It seals `limine.conf` into the loader instead of using path hashes, and never touches snapshot images or the fallback loader. §5.3 is rewritten to match.
- **Commands are `omarchy secureboot enable|disable|status|sign|windows …`.** Each is a thin `bin/omarchy-secureboot-*` wrapper that runs the engine with `sudo`.
- **Vendoring is a scripted transform.** `bin/omarchy-dev-vendor-secureboot <commit>` copies OmaSecBoot at a pin and applies ordered sed renames, recorded in `install/secureboot/VENDORED`. Nothing vendored is edited by hand; a fix is a new rule or a pin bump.
  - The engine ships in `install/secureboot/`, because the omarchy package ships `install/` wholesale.
  - Its 161 hermetic cases run from `test/shell.d/secureboot-test.sh`.
  - Its design documents are verbatim in `docs/secureboot/`.
- **The hook and units are written into `/etc` at `enable` time** by `omarchy-secureboot-integrate`, since omarchy-pkgs is read-only here. They run as root and call the engine by absolute path, so integration refuses an engine that anyone but root can change (a dev checkout in `$HOME`).
- **`omarchy update` gets a Secure Boot step** (`omarchy-update-secureboot`) after the log analysis. It refreshes the hook and units, then runs `status --quiet`. On failure it prints a red line and never fails the update.
- **`sbctl` and `efibootmgr` join `install/omarchy-other.packages`**, so `enable` works from the offline mirror.
- **Menu rows:**
  - Setup > Security > Secure Boot: UEFI only, hidden on Apple hardware.
  - Remove > Security > Secure Boot: shown when enabled.
  - System > Reboot to Windows: shown when the Windows entry is enabled and the firmware has one clear target.

**What would change it.** Upstream shipping its own Secure Boot route (a Microsoft-signed shim, per `omarchy-iso/plans/consumer-secure-boot.md`), or OmaSecBoot changing its layout enough that the transform stops being mechanical.

## Findings, 2026-09-26: Phase 2 in QEMU

The VM is the Row E install under OVMF with Microsoft's keys and Secure Boot off. Firmware-menu steps were done offline with `virt-fw-vars`. That means deleting the PK and setting `SecureBootEnable`.

- **Row K passes.**
  - Run 1 creates keys, seals and signs the loader and UKI, backs up the firmware keys, installs the hook and watchers, and asks to delete only the PK.
  - Run 2, in Setup Mode, appends db, KEK, then PK, keeping 7 vendor entries.
  - Run 3 asks to turn Secure Boot on. The machine then boots enforcing, and `status` reports nothing to do. `sbctl verify` flags only `EFI/BOOT/BOOTX64.EFI`, the raw fallback loader, by design.
- **Row L passes.** One flipped byte in the UKI: the firmware refuses it (`LoadImage failure`, access denied). With Secure Boot turned off, the same disk boots, and `status` names the file and exits 1.
- **Row M passes, in two halves.**
  - An edit to `limine.conf` that bypasses the running watchers (an offline edit) stops the loader with `CHECKSUM MISMATCH FOR CONFIG FILE`.
  - A hand edit on the running system is re-sealed by the watcher within seconds and boots.
- **Row N passes.** A real `pacman -S linux-omarchy`:
  - The new UKI is signed by sbctl's initcpio hook.
  - The loader is re-sealed by Limine's hook and ours.
  - A new snapper snapshot's history UKI is a signed copy, and its entry boots with Secure Boot on.
- **The update step works:**
  - silent when healthy
  - puts a deleted hook back
  - prints its red line when the watchers are down; `sign` then brings them back
- **`disable` works.** It refuses with Secure Boot on. With it off, it returns the boot files and `/etc/default/limine` to stock and removes the hook and units. The keys and the firmware backup stay.
- **Environment note.** KVM can't run OVMF's SMM build under WSL2's nested virtualization (`KVM: entry failed`). The rows ran on Ubuntu's non-SMM `OVMF_CODE_4M.fd`, which still enforces Secure Boot. SMM only protects the variable store from the OS, which these rows don't test.
- **Not run:** the hardware rows (discrete GPU option ROM, Windows with BitLocker and BootNext), and `windows setup`/`bootnext` (no Windows in the VM).
- **Upstream caution.** OmaSecBoot 0.1.0 has one machine with a full hardware record; the manual page says so.
- **ISO follow-up.** OmaSecBoot asks installers to drop `99-omarchy-limine.hook`, which copies a raw loader over the sealed one after Limine upgrades. It lives in our `omarchy-iso` orchestrator (`phases_impl.py`). The watcher repairs it either way; dropping it, or running `limine-install` in its place, is a small Phase 2 ISO change not yet made.

## 2026-09-26: Phase 1 shape

**Decision.**
- **A user's password can be a file** (`password = { file = … }`), as an alternative to `password_hash`. The spec's default `same_as_user` passphrase otherwise has no plaintext to format LUKS with on an unattended install. With only a hash, `same_as_user` works interactively (it prompts) and `--yes` refuses it.
- **Theme and agent in Phase 1; extra packages from the offline mirror only.**
  - The theme is applied at install.
  - The agent installs at first login through a notification, which needs an `omarchy` fork change (`install-toml-agent`). Installing it needs a network and mise, and recording only its name leaves a default `omarchy agent` refuses to launch.
  - First-boot network installs of extra packages are deferred.
- **Python owns config, Bash owns disks.** `chefs_kitchen_config` parses, validates and compiles, and calls the configurator's Bash helpers (`disk-inspect.sh`, `free-space.sh`) for everything that touches disks, so the wizard and `chefs-kitchen` can't disagree about a disk.
- **The wizard installs through `install.toml`** with `on_existing_data = "wipe"` and the confirmed disk's `expect_fingerprint`. Its direct JSON writers are gone.
- **Five `omarchy-iso` branches, stacked on `visible-encryption`:** `install-toml`, `swap-strategies`, `home-disk`, `wizard-install-toml`, `desktop-packages`. Plus two `omarchy` branches from `quattro`: `install-toml-agent` and `unattended-installs-manual`.

**What would change it.** Upstream taking a different shape for declarative installs.

## Findings, 2026-09-26: Phase 1 on test ISOs

- **Row E passes.** An unattended cidata install from `install.toml` (password as a file, encrypted, by serial) boots with the user's password. It gets the hostname, timezone, git identity and SSH key from the file, the same LUKS2 → btrfs layout, zram plus a RAM-sized swapfile and `resume=` as a wizard install, and 0 failed units. `/etc/chefs-kitchen/install.toml` has no secrets. The wipe summary and fingerprint are in the install log.
- **Row F passes.** `on_existing_data = "abort"` against the Windows-like disk refuses at boot, with the summary, the reason and the fix (the fingerprint to pin), on screen and in the log.
- **Row G passes.** A stale `expect_fingerprint` refuses. The current one, with `on_existing_data = "wipe"`, goes ahead.
- **Row H passes.** `/home` on a second encrypted disk boots with one passphrase prompt and zero console password requests. `/home` is on its own LUKS2 volume, unlocked by `/etc/cryptsetup-keys.d/omarchy_home.key` (0400), and a root snapper snapshot still works.
- **Row I passes.** `swap.strategy = "zram"` gives zram only: no swapfile, no `resume=`.
- **Row J passes** in unit tests. An unknown key or a plaintext secret fails `validate`, naming the key.
- **The wizard's own path works on the ISO.**
  - A full-disk encrypted wizard install goes through `install.toml` without a second confirmation, and the result records the disk by serial, with its fingerprint.
  - A free-space wizard install is partitioned by `chefs-kitchen`, and `qemu-img map` shows no writes inside the Windows partitions.
- **Loading from USB works.** "L" at the greeter finds `install.toml` on a USB stick and installs it interactively.
- **Theme, agent and extra packages work.** The Nord theme is applied, `claude` is recorded for first login, and `qmk-hid` installed from the offline mirror.
- **Three bugs only the VM runs caught**, all fixed and now covered by tests:
  - `chefs-kitchen` wrote refusals to stderr while stdout was buffered through the log pipe, so the reason scrolled away above the summary and never reached the log.
  - `parted` read the home disk's `-1MiB` end as options, fixed with `--`.
  - The free-space helper's Bash bridge shifted away its first argument.
- **Not run:** the upstream `omarchy-iso-test` harness, which needs an Omarchy host. Its wizard scenarios now install through `install.toml` by construction. It was updated for the Phase 0 screens but not run.

## 2026-09-25: Name, upstreaming, and the Secure Boot tool

**Decision.**
- **Name.** The installer is called Chefs Kitchen, and its CLI is `chefs-kitchen`: `chefs-kitchen validate|plan|install`, `/etc/chefs-kitchen/install.toml` on installed systems, and the `chefs_kitchen_config` Python package. Commands on installed systems keep Omarchy's own naming (`omarchy secureboot`, `zz-omarchy-secureboot.hook`). The umbrella repo, the forks' `kitchen` branches and the product name "Omarchy: The Kitchen Is Open" stay as they are. This closes spec §8 question 5.
- **Upstreaming waits until all phases are done.** Upstreamable changes stay on their own topic branches from `quattro` until then (today: `t2-bcm-firmware-fetcher`, `wipe-summary`, `visible-encryption`, `quiet-cloud-init`). This closes §8 question 4.
- **Phase 2 vendors OmaSecBoot** (`peregrinus879/omasecboot`, MIT) into the `omarchy` fork at a pinned commit, with attribution. It keeps the hard-won parts (enrolment steps, BootNext dual boot, hook ordering, firmware workarounds) close to upstream so their fixes cherry-pick, and reshapes the command layer into `omarchy secureboot`. This closes §8 question 3.
- **Deferred:** checking the laptop hint on real hardware.

**Why vendor.** As of 2026-09-25, OmaSecBoot is v0.1.0 with one maintainer, 67 commits in the last 30 days, about 3,300 lines of Bash with tests, one field report (a Framework 13 AMD), and no AUR package.
- Depending on it as a package ties §5 to one person's pace and design choices, behind a v0.1.0 CLI that isn't `omarchy secureboot`.
- Writing our own would re-learn its firmware lessons from zero.
- Vendoring costs manual syncing, so keep the diff against it small.

**What would change it.** OmaSecBoot reaching a stable, packaged release whose behaviour matches §5.3: then depend on it (option A) and keep only a thin wrapper.

## Findings, 2026-09-25: cloud-init on the live ISO

- **Arch's live-ISO profile enables five cloud-init units** (`cloud-init-local`, `-main` and `-network`, plus `cloud-config` and `cloud-final`), and all of them log with `StandardOutput=journal+console`. cloud-init runs whenever a drive labelled cidata is attached. With a cidata drive whose config the installer couldn't load, its output (including SSH host key fingerprints, which `keys_to_console` also writes straight to `/dev/console`) covered the wizard on tty1.
- **Fixed on `quiet-cloud-init`:**
  - A `cloud-.service.d` drop-in; the prefix applies it to every `cloud-*.service` unit.
  - `cloud.cfg.d/90-omarchy-quiet-console.cfg`, which sets `ssh.emit_keys_to_console: false` and `no_ssh_fingerprints: true`.
- **Verified on a test ISO with the invalid cidata drive attached:**
  - tty1 stays clean through the picker.
  - `systemctl show` reports `StandardOutput=journal` for the cloud-init units.
  - cloud-init still ran, and its fingerprint lines are in the journal.
  - The config passes `cloud-init schema`, given the `#cloud-config` header that user-data needs and `cloud.cfg.d` files don't.

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
