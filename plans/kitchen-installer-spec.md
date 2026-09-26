# Omarchy "The Kitchen Is Open": Installer Spec

**Status:** Draft v2 · 2026-09-25. Rescoped from v1: the Custom screen and TPM unlock were cut or deferred. Phase 0 is in progress; §2.3, §3 and §7 were updated to match what was built.
**Base:** `omacom/omarchy` (formerly `basecamp/omarchy`) 4.0.0.alpha and `omarchy-iso` (both at HEAD on 2026-09-25)
**Scope:** Design, with Phase 0 under way on the forks' `wipe-summary` and `visible-encryption` branches.

> **Naming.** The installer is called Chefs Kitchen, and its CLI is `chefs-kitchen` (decided 2026-09-25, §8 question 5). Commands on the installed system keep Omarchy's `omarchy <noun> <verb>` convention, which comes from the `omarchy-*` scripts in `bin/`. That way the fork stays easy to rebase on upstream.

---

## 0. Scope

| # | Change | Size | Ships in |
|---|--------|------|----------|
| 4 | Last-chance wipe summary and disk-picker fixes | S | Phase 0 |
| 5 | Encryption as a visible choice (still the default) | S | Phase 0 |
| 3 | `chefs-kitchen install --config install.toml`, trimmed to the essentials | M | Phase 1 |
| 1 | Signed boot as a post-install command (`omarchy secureboot enable`) plus a docs fix | S–M | Phase 2 |

**Cut or deferred** (see §6 for the reasoning and what would bring each back):
- the Custom screen
- ext4/xfs
- systemd-boot as an alternative
- reusing an existing `/home`
- TPM2 unlock and the systemd initramfs migration it needs
- config from a kernel-parameter URL
- lock-file drift reports
- `chefs-kitchen config export`
- encrypted recovery-key output

**Guiding rule.** Omakase stays the wizard's only recipe. Anything beyond the defaults goes in `install.toml`, not in more screens.

---

## 1. What upstream does today (the parts this spec touches)

**Flow.**
- `root/.automated_script.sh` tries `omarchy-cidata-load` first. If that fails, it runs `root/configurator`, a bash/gum wizard of about 1,250 lines.
- The wizard writes these files to `/root`:
  - `user_configuration.json` (archinstall format, plus an `omarchy_install` block)
  - `user_credentials.json`
  - loose `*.txt` flag files
- `omarchy-iso-install` then runs the Python orchestrator: 14 phases in `orchestrator/phases_impl.py`, using archinstall as a library.

**Disk picker.** The picker line looks like `/dev/nvme0n1 (476.9G) - Samsung … [vfat, ntfs, ext4(/mnt)]`. That shows the filesystem type only. There are no partition sizes, labels, OS names or serial numbers. Two identical drives render identically.

**Wipe confirmation.** `confirm_disk_overwrite` (`configurator:949`) shows:
- "Everything will be overwritten. There is no recovery possible."
- "Confirm overwriting /dev/XXX" with [Yes, install] / [No, change it]

**Bugs in the same code:**
- The `cidata` drive is not excluded from the picker. If it is present but its config is invalid, the wizard runs and offers that drive as a wipe target.
- `lsblk -r` whitespace parsing shifts columns when FSTYPE is empty.
- The full-disk path has no minimum-size check, so `main_partition_size` can go negative.

**Encryption.** It is on by default. Unencrypted installs exist, but only via **Ctrl+C on the confirm screen** (`configurator:959`, "Press Ctrl+C for unencrypted install."). The LUKS passphrase is always the login password.

`user_encrypt_installation.txt` does not control encryption. It drives two things:
- SDDM autologin in `configure_login` (`phases_impl.py:1408`)
- a `cryptdevice=` assertion in `validate_boot` (`phases_impl.py:1665`)

It has to be kept in sync with the JSON by hand.

**Autoinstall.** A drive labelled `cidata` with the two JSON files skips the wizard. The only validation is that the files exist. The LUKS passphrase sits in plaintext in the JSON.

**Secure Boot.** The installer never checks it.
- The ISO boots unsigned GRUB (`configs/profiledef.sh`).
- The installed system already boots a UKI through Limine (`finalize_limine_boot`).
- `manual/02-getting-started.md:7` tells users to turn off Secure Boot "and/or TPM".

---

## 2. Change #4: last-chance wipe summary

This ships first. It has no dependencies and gives the most value per line of code.

### 2.1 Screen

```
  THIS WILL ERASE A DISK
  ──────────────────────────────────────────────────────────────────────
  Target   Samsung SSD 980 PRO 500GB · 465.8 GiB · NVMe
           serial S69ENX0T812345
           /dev/nvme1n1  (by-id: nvme-Samsung_SSD_980_PRO_500GB_S69ENX0T812345)

  What dies:
   #  SIZE       FILESYSTEM   LABEL      WHAT'S ON IT
   1  260 MiB    vfat         SYSTEM     EFI boot files · Windows Boot Manager
   2  16 MiB     —            —          Microsoft reserved
   3  464.9 GiB  ntfs         Windows    ~212 GiB used · BitLocker off
   4  650 MiB    ntfs         WinRE      Windows recovery

  Not touched:
   /dev/nvme0n1  Samsung SSD 980 PRO 500GB · S69ENX0T899999 · Omarchy (LUKS2 + btrfs)
   /dev/sda      SanDisk Ultra 32 GiB · install medium

  What gets created:
   1  2 GiB      vfat          /boot
   2  463.8 GiB  LUKS2 → btrfs /  (@, @home, @log, @pkg) · zram + 32 GiB hibernation swapfile

  Type  nvme1n1  to erase this disk, or press Esc to go back
  > _
```

### 2.2 Rules

**Data.** Use `lsblk -J -b -o NAME,PATH,SIZE,FSTYPE,LABEL,PARTLABEL,PARTTYPE,MODEL,SERIAL,TRAN,MOUNTPOINTS`, plus `blkid -p` and `wipefs -n`. JSON output fixes the `-r` column-shift bug.

**"What's on it" probes.** All probes are read-only and best-effort. A timeout shows "—" and never fails the screen.

| Content | How to detect it |
|---|---|
| ESP | Mount `ro` and look for `EFI/Microsoft`, `EFI/limine`, `EFI/systemd` and `EFI/*/grubx64.efi` |
| BitLocker | Reuse the existing `-FVE-FS-` probe (`detect_bitlocker`) |
| LUKS | `cryptsetup luksDump` for label and version. Never unlock. |
| ext4, btrfs, ntfs | Mount `ro` (with `noload` for ext4) and read `etc/os-release` (or `@/etc/os-release` on btrfs), plus used space. Skip partitions that are already mounted. |

**Typed confirmation.**
- It is required whenever `wipefs -n` finds any signature on the target. The user types the kernel name.
- A blank disk gets a plain Yes/No.
- The "What's on it" column is what tells identical drives apart. Typing forces the user to read it.

**"Not touched" list.** Always shown when more than one disk is present, so the user sees the drive they *didn't* pick.

**Mounted or swap-active partitions** on the target are shown in red. The screen won't continue until they are released. Today `omarchy-iso-cleanup-disk` releases them silently.

**Free-space mode** uses the same screen. "What dies" becomes "Nothing is erased", followed by the free region to be used.

**Unattended installs.** `chefs-kitchen plan` and `chefs-kitchen install` render the same table to stdout and the install log (see §4.4).

### 2.3 Picker fixes in the same PR

- Exclude every disk labelled `cidata`/`CIDATA`.
- Exclude `mmcblk*boot*` and `mmcblk*rpmb`.
- Add serial and a short "what's on it" to each picker line, so identical drives never render identically anywhere. Order the line from most to least telling (path, size, what's on it, serial, model), so an 80-column console truncates the model name, which is the one thing two identical drives share.
- Refuse full-disk installs below ESP + 32 GiB. This matches the existing free-space minimum at `configurator:595`.

---

## 3. Change #5: encryption as a visible choice

### 3.1 UX

Remove the Ctrl+C toggle. Encryption gets its own screen, after the install mode and right before the wipe summary, on every path: full disk, free space and deferred provisioning. (The account summary comes before disk selection in the wizard, so it can't carry this row.)

```
  Encrypted: you type your password at boot, and the disk is protected if the machine is lost.
  Not encrypted: for servers, VMs, or machines whose data lives elsewhere.

  Disk encryption
  > Encrypted (recommended)
    Not encrypted
```

The wipe summary that follows shows the result under "What gets created" (`LUKS2 → btrfs` or `btrfs`).

- **Default.** Encrypted, always.
- **Laptop hint.** If `/sys/class/dmi/id/chassis_type` is a portable type (8, 9, 10, 14, 30, 31, 32) and the user picks "Not encrypted", one line appears on the wipe summary: *"This looks like a laptop. If it's lost or stolen, anyone can read the disk."* There is no second confirmation.
- **Separate passphrase.** Out of scope for the wizard. It is available in TOML (§4.2).

### 3.2 Plumbing

- The configurator no longer writes `user_encrypt_installation.txt`. Whether the install is encrypted comes from the configuration itself, so the flag and the actual encryption can no longer disagree:
  - full disk: the `disk_encryption` block archinstall acts on
  - pre-mounted (free space): `omarchy_install.storage.luks_uuid`, which the configurator always writes (`null` when unencrypted)
  - From Phase 1 the plan (§4) produces that configuration, so the rule doesn't change.
- `configure_login`'s autologin rule stays as it is: encrypted means autologin (the LUKS prompt is the auth boundary), unencrypted means an SDDM login. That rule remains correct because v2 has no silent TPM unlock. **If TPM unlock is ever added, this rule must change** (see §6).
- `validate_boot` asserts `cryptdevice=` when the plan says encrypted, and asserts it is **absent** when the plan says unencrypted. Today only the first half is checked.
- Legacy cidata installs still accept the flag file. It only decides for a pre-mounted config with no `luks_uuid` key. When it disagrees with the configuration, the install log says so and the configuration wins.

---

## 4. Change #3: declarative installs (trimmed)

### 4.1 Commands

```
chefs-kitchen validate install.toml                    # schema + semantic checks, no hardware access (CI-friendly)
chefs-kitchen plan     --config install.toml           # resolve disks, print the wipe summary; touches nothing
chefs-kitchen install  --config install.toml           # interactive: shows the wipe summary, typed confirm
chefs-kitchen install  --config install.toml --yes     # unattended: guarded by [disk].on_existing_data
```

**Config sources, in order:**
1. `--config PATH`
2. `install.toml` on a `cidata` drive
3. The legacy cidata JSON pair (still accepted)
4. The wizard

The wizard gains one entry on its first screen: **"Load install.toml from USB"**.

**Every clicked install is also a described one:**
- The wizard writes `/root/install.toml`, then runs `chefs-kitchen install --config /root/install.toml`.
- The installer copies that file, with secrets stripped, to `/etc/chefs-kitchen/install.toml` on the target.

### 4.2 Schema v1

```toml
schema = 1

[system]
hostname = "marvin"
timezone = "America/Toronto"
keyboard = "us"

[[users]]
name          = "kevin"
full_name     = "Kevin"                         # optional, used for git config
email         = "…"                             # optional, used for git config
password_hash = "$6$…"                          # openssl passwd -6
ssh_authorized_keys = []

[disk]
target = { serial = "S69ENX0T812345" }          # or { by_id = "nvme-…" } / { wwn = "…" }
                                                # { path = "/dev/vda" } is allowed; warns on bare metal
mode = "wipe"                                   # "wipe" | "free-space"
on_existing_data = "abort"                      # "abort" | "wipe"
# expect_fingerprint = "sha256:…"               # optional: wipe only if the disk still looks like this

[disk.home]
location = "same"                               # "same" | "disk"
# disk = { serial = "S69ENX0T899999" }          # when location = "disk"

[swap]
strategy = "zram+hibernate"                     # "zram+hibernate" (default) | "zram" | "none"

[encryption]
enabled    = true
passphrase = { same_as_user = "kevin" }         # default. Alternatives:
# passphrase = { prompt = true }                # ask at install time (interactive only)
# passphrase = { file = "luks.pass" }           # relative to install.toml (cidata)

[desktop]
theme = "tokyo-night"                           # any name `omarchy-theme-set` accepts
agent = "claude"                                # any name `omarchy-default-agent` accepts

[packages]
extra = []                                      # offline mirror if present, otherwise first boot with network

[network]
tailscale_authkey = { file = "tailscale.key" }

[provisioning]
defer = false
```

**Why only these knobs.**

The options are limited to ones that need **no new orchestrator branches beyond small, isolated ones**:

| Knob | Orchestrator change |
|---|---|
| `swap.strategy = "zram"` | Skip `configure_hibernation` |
| `swap.strategy = "none"` | Also drop the zram-generator drop-in |
| `disk.home.location = "disk"` | Second btrfs filesystem mounted at `/home`. When encrypted: its own LUKS2 volume, unlocked from `/etc/crypttab` with a keyfile in `/etc/cryptsetup-keys.d/` on the encrypted root, so there is still one prompt at boot. |
| everything else | Maps 1:1 onto what the configurator already writes |

- The filesystem stays btrfs, the bootloader stays Limine, and the subvolume layout is unchanged.
- `/home` on a second disk only affects the `@home` subvolume. It moves off the root disk and onto its own disk. Snapshots and factory reset still cover `/`.

### 4.3 Validation rules

**`chefs-kitchen validate`** (static, no hardware access):
- It rejects plaintext secrets. The only exception is `passphrase = { insecure_plaintext = "…" }`, which prints a warning in every mode.
- It rejects unknown keys. A typo must never be silently ignored.
- `theme` and `agent` must be names the ISO knows.

**`chefs-kitchen plan`** (probes hardware):
- **Target disk.** `target` must resolve to **exactly one** disk. That disk must never be the install medium or a `cidata` drive, and must be at least ESP + 32 GiB.
- **Home disk.** `home.disk` must resolve to a different disk than `target`. It gets its own "What dies" block, and in interactive mode its own typed confirmation.
- **`on_existing_data = "abort"`** is the unattended default. If either disk has any signature, the install stops, prints the wipe table and hints at the two ways forward.
- **`expect_fingerprint`** is a sha256 over the partition-table type plus, for each partition, its start, size, type GUID and filesystem UUID. `chefs-kitchen plan` prints the current value so it can be pasted into the config. It is the unattended equivalent of "yes, *that* drive, with *that* data on it".

### 4.4 Implementation

**Compiler shim.** `chefs_kitchen_config` is a Python package: stdlib `tomllib` plus dataclasses, so no new dependencies. It turns the TOML into **today's** `user_configuration.json`, `user_credentials.json` and flag files. The orchestrator therefore runs unchanged, except for the swap and home branches above. Reading the plan directly can come later, once the shim has proved itself.

**Files touched:**

| File | Change |
|---|---|
| `omarchy-iso/configs/airootfs/usr/share/omarchy-iso/chefs_kitchen_config/` | **New.** `schema.py`, `resolve.py` (disk selectors via `/dev/disk/by-id` and `lsblk -J`), `plan.py` (wipe table and fingerprint), `compile_archinstall.py` |
| `…/usr/local/bin/chefs-kitchen` | **New** dispatcher |
| `…/usr/local/bin/omarchy-cidata-load` | Also accept `install.toml` |
| `…/root/.automated_script.sh` | cidata → `chefs-kitchen install --config … --yes` |
| `…/root/configurator` | Write `install.toml`. Remove the direct JSON writers and the Ctrl+C toggle. Add the wipe summary and "Load from USB". |
| `orchestrator/phases_impl.py` | Swap-strategy skip in `configure_hibernation`. `/home` disk mount and crypttab. Strip secrets and copy `install.toml` to the target. `validate_boot` encryption assertion in both directions. |
| `omarchy/manual/51-unattended-installs.md` | Rewrite around `install.toml` |
| `omarchy-iso/bin/omarchy-iso-test` | Scenarios driven from TOML fixtures |

---

## 5. Change #1: signed boot as a post-install command

### 5.1 Why post-install, not in the installer

**The USB can't boot with Secure Boot on.** Without a Microsoft-signed shim (months of `shim-review`), the stick can't boot with Secure Boot enforcing on factory keys, whatever the installer does.

**The installed system is the right place.** Putting Secure Boot into Setup Mode, enrolling your own keys and signing the boot chain is something the installed system can do as well as the installer. It is also far easier to recover from if it goes wrong, because the machine already boots.

**It stays separate from the install path.** Keeping signed boot out of the installer means the 14 orchestrator phases don't change, and a signing failure can never take down a fresh install.

### 5.2 Command

This follows Omarchy's convention: `bin/omarchy-secureboot-*` with `omarchy:summary` headers, exposed as `omarchy secureboot <verb>`.

```
omarchy secureboot status     # SB on/off, Setup Mode, our keys enrolled?, `sbctl verify` summary
omarchy secureboot enable     # guided: keys → sign → (reboot to Setup Mode if needed) → enroll → verify
omarchy secureboot disable    # stop re-signing hooks; tell the user how to turn SB off in firmware
```

### 5.3 `enable` flow

1. **Check prerequisites.**
   - The machine must boot UEFI with Limine and a UKI. That's true of every Omarchy install; BIOS installs are refused with an explanation.
   - Install `sbctl` if missing.
2. **Create keys.** Run `sbctl create-keys`. Keys land in `/var/lib/sbctl` on the (normally encrypted) root and never on the ESP.
3. **Harden Limine.**
   - Enroll the `limine.conf` checksum into `limine_x64.efi` using limine-entry-tool's config-enrollment setting in `/etc/default/limine`.
   - Set `hash_mismatch_panic: yes`, overriding the Omarchy template's `no`.
   - Turn off the config editor.

   With a checksum enrolled, Limine refuses a modified `limine.conf`. The UKI entries are EFI loads, so the firmware checks their signatures.
4. **Sign the boot chain.** Sign `limine_x64.efi`, every UKI in `EFI/Linux/` and the fallback UKI with `sbctl sign -s`, so sbctl tracks them for re-signing.
5. **Install the hooks.**
   - `zz-omarchy-secureboot.hook` is a pacman hook ordered after sbctl's own `zz-sbctl.hook`.
   - A Limine post-hook runs after `limine-update` and `limine-snapper-sync`. It re-enrolls the config checksum, re-signs `limine_x64.efi`, and signs new snapshot UKIs (`*.efi_sha256_*`, `*.efi_b3_*`).
   - **Failure policy:** never leave an unsigned boot artifact in place of a signed one. The hook fails the transaction loudly instead.
6. **Check Setup Mode.** If the firmware isn't in Setup Mode:
   - Explain the one menu item needed ("Reset to Setup Mode" or "Clear Secure Boot keys").
   - Show per-vendor hints from `secureboot-vendors.toml`, keyed on `/sys/class/dmi/id/sys_vendor`.
   - Offer `systemctl reboot --firmware-setup`.
   - Leave a one-shot marker, so the next login's `omarchy secureboot status` resumes at step 7.
7. **Enroll the keys.** Run `sbctl enroll-keys --microsoft`.
   - Microsoft's keys are **on by default** and are *required* with a discrete GPU. Its option ROM is Microsoft-signed, and without it the firmware can skip it and leave you with no display.
   - `--firmware-builtin` is offered on laptops as an extra safety net.
8. **Turn Secure Boot on and verify.**
   - The user enables Secure Boot in firmware and reboots.
   - `omarchy secureboot status` must show SB enabled, user mode, and `sbctl verify` clean.
9. **Dual boot.** If a Windows boot entry exists, register Windows as a **firmware BootNext** entry rather than a Limine chainload. Otherwise every re-signed `limine_x64.efi` changes Windows' TPM measurements and triggers BitLocker recovery. This is the approach proven in `peregrinus879/omarchy-secureboot`.

**Prior art.** `peregrinus879/omarchy-secureboot` already implements most of this on Omarchy. Evaluate vendoring it, with attribution and licence permitting, before writing from scratch.

### 5.4 Docs

| File | Change |
|---|---|
| `omarchy/manual/02-getting-started.md:7` | Ships with Phase 2, when the command it names exists. Replace with: "Secure Boot: if it's on, switch it off or put it in **Setup Mode** to boot the installer. After installing, run `omarchy secureboot enable` to turn it back on with keys owned by your machine. Leave the TPM alone; nothing needs it disabled." |
| `omarchy/manual/44-mac-support.md:19–28` | Keep. T2 Macs use Apple's own Secure Boot with no user key enrollment. Add one sentence saying why. |
| New manual page: "Secure Boot" | The `enable` flow, recovery (turning SB off in firmware always gets you back in), and firmware-update notes |

---

## 6. Deferred, and what would bring each back

| Item | Why it was deferred | What brings it back |
|---|---|---|
| Custom screen | Duplicates TOML and multiplies the test matrix | Real users asking for an option that TOML can't serve |
| ext4 / xfs | Loses snapshots, snapshot boot and factory reset, Omarchy's best features | Probably never |
| systemd-boot option | Only needed if Limine's Secure Boot enforcement proves fragile | Hardware failures in §5 testing |
| Reuse existing `/home` | UID and LUKS edge cases | `/home` on its own disk makes the next reinstall a natural test case |
| **TPM2 unlock** | Needs the systemd initramfs migration (snapshot-overlay hook risk), first-boot TPM setup (because PCR 7 changes after enrollment), recovery-key screens, and **an autologin rule change**: with silent unlock, encrypted autologin would boot a stolen laptop to the desktop | `omarchy secureboot enable` running cleanly on your own hardware for a few weeks. `plans/kitchen-installer-spec-v1-full.md` §6.5 has the full design (PCR 7 + 15, `tpm2-measure-pcr`). |
| Config from a kernel-parameter URL, lock-file drift, `config export`, encrypted recovery-key output | Nice-to-haves | When someone needs them |

---

## 7. Phases and tests

| Phase | Contents | Exit criteria |
|---|---|---|
| **0** | §2 wipe summary and picker fixes. §3 visible encryption choice. | Rows A–D |
| **1** | §4 TOML: validate, plan, install. Compiler shim. cidata TOML. Wizard writes TOML. `/home` disk and swap branches. | Rows E–J, plus every existing `omarchy-iso-test` scenario passing from TOML |
| **2** | §5 `omarchy secureboot`, which runs on installed systems and is independent of the ISO. §5.4 docs, including line 7. | Rows K–N, plus hardware |

The harness is QEMU plus OVMF, extending `bin/omarchy-iso-test`. OVMF vars without enrolled keys start in Setup Mode.

| Row | Scenario | Asserts |
|---|---|---|
| A | Two identical virtio disks, one with a Windows-like layout | They are distinguishable in the picker. The wipe summary lists partitions. Typed confirm is required. |
| B | Blank target | Plain Yes/No confirm |
| C | cidata drive present *and* invalid | The wizard never offers it |
| D | "Not encrypted" chosen | No LUKS. No `cryptdevice=`. SDDM login screen, no autologin. |
| E | TOML equivalent of the default install | Boots. Parity with a wizard install. `/etc/chefs-kitchen/install.toml` has no secrets. |
| F | `on_existing_data = "abort"` against a disk with data | Refuses. Table in the log. |
| G | Stale `expect_fingerprint` | Refuses |
| H | `home.location = "disk"`, encrypted | One prompt at boot. `/home` on disk 2. Snapshot of `/` still works. |
| I | `swap.strategy = "zram"` | No swapfile, no `resume=` |
| J | Unknown key or plaintext secret in TOML | `chefs-kitchen validate` fails with the key name |
| K | Installed VM, `omarchy secureboot enable` in Setup Mode | Enrolled. Boots with SB enforcing. `sbctl verify` clean. |
| L | Flip a byte in the UKI on the ESP | Firmware refuses it |
| M | Edit `limine.conf` by hand | Limine refuses (hash mismatch) |
| N | Kernel update plus new snapper snapshot | New UKI and snapshot UKIs signed. Config re-enrolled. Reboots cleanly. |

**Hardware for Phase 2:**
- one desktop with a discrete GPU, to prove `--microsoft` is needed for the option ROM
- one laptop with Windows and BitLocker, to test the BootNext path

---

## 8. Open questions

1. **Limine config-enrollment key.** Confirm the exact key name in the shipped `limine-mkinitcpio-hook`, and whether `limine-snapper-sync` re-enrolls on its own.
2. **Microsoft 2023 CAs.** Microsoft's 2011 Secure Boot CAs expire during 2026. Confirm that the shipped sbctl's `--microsoft` bundle includes the 2023 UEFI CA and KEK.
3. ~~**Vendor vs. write.**~~ Decided 2026-09-25: vendor OmaSecBoot (MIT) into the `omarchy` fork at a pinned commit, with attribution. Keep its enrolment, BootNext and firmware workarounds close to upstream so fixes cherry-pick cleanly, and reshape the command layer into `omarchy secureboot`. See `docs/decisions.md`.
4. ~~**Upstreaming.**~~ Decided 2026-09-25: upstream PRs wait until all phases are done. Upstreamable work stays on topic branches from `quattro` until then.
5. ~~**Name.**~~ Decided 2026-09-25: Chefs Kitchen, CLI `chefs-kitchen`.

## Sources

- Omarchy source: `omacom/omarchy`, `omarchy-iso`. File and line references are from the 2026-09-25 HEAD.
- Upstream plan: `omarchy-iso/plans/consumer-secure-boot.md`
- Limine Secure Boot semantics: https://github.com/limine-bootloader/limine/blob/trunk/USAGE.md
- Working Omarchy + sbctl + Limine reference: https://github.com/peregrinus879/omarchy-secureboot
- sbctl: https://man.archlinux.org/man/sbctl.8
