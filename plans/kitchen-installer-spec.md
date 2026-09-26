# Omarchy "The Kitchen Is Open": Installer Spec

**Status:** Draft v2 · 2026-09-26. Rescoped from v1: the Custom screen and TPM unlock were cut or deferred. Phases 0, 1 and 2 are built; §2–§5 and §7 were updated to match.
**Base:** `omacom/omarchy` (formerly `basecamp/omarchy`) and `omarchy-iso`, both on upstream's `quattro` branch. That's the 4.x development line; 4.0.x releases (v4.0.4 on 2026-09-15) are cut from branches of their own. File references are from 2026-09-25, and the forks were last rebased on 2026-09-26.
**Scope:** Phases 0–2 are built on the forks' topic branches. Phase 2's hardware rows are still open (§7).

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
chefs-kitchen plan     --config install.toml [--yes]   # resolve disks, print the wipe summary; touches nothing
                                                       # (--yes applies the unattended rules)
chefs-kitchen install  --config install.toml           # interactive: shows the wipe summary, typed confirm
chefs-kitchen install  --config install.toml --yes     # unattended: guarded by [disk].on_existing_data
```

**Config sources, in order:**
1. `--config PATH`
2. `install.toml` on a `cidata` drive
3. The legacy cidata JSON pair (still accepted)
4. The wizard

The wizard gains one entry on its first screen: **"Load install.toml from USB"**. The greeter reads it as "type L and press Return". It finds `install.toml` at the top of any drive other than the install medium, copies that drive privately to `/root/usb`, and runs `chefs-kitchen install` interactively (summary, typed confirmation, passphrase prompt).

**Every clicked install is also a described one:**
- The wizard writes `/root/install.toml` and the user's password to a private file under `/run/chefs-kitchen/wizard/`, then runs `chefs-kitchen install --config /root/install.toml --yes`. It has already shown the wipe summary and had it confirmed, so the file says `on_existing_data = "wipe"` and pins `expect_fingerprint` to the disk as confirmed: no second confirmation, and a refusal if the disk changed in between. The disk is named by its serial when no other disk shares it, else its by-id name, else its path.
- The wizard no longer writes the orchestrator's JSON itself. `chefs-kitchen`'s compiler is the only place those files come from.
- The installer copies that file, with secrets stripped, to `/etc/chefs-kitchen/install.toml` on the target. The copy is written from the parsed config rather than copied, so nothing in the original can carry a secret through.

### 4.2 Schema v1

```toml
schema = 1

[system]
hostname = "marvin"
timezone = "America/Toronto"
keyboard = "us"

[[users]]                                       # exactly one in v1 (none with provisioning.defer)
name          = "kevin"
full_name     = "Kevin"                         # optional, used for git config
email         = "…"                             # optional, used for git config
password_hash = "$6$…"                          # openssl passwd -6
# password    = { file = "kevin.pass" }         # instead of password_hash; needed for an
                                                # unattended encrypted install with same_as_user
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
theme = "tokyo-night"                           # any theme the ISO ships, named as `omarchy-theme-set` names it
agent = "claude"                                # any name `omarchy-default-agent` accepts; installs at first login

[packages]
extra = []                                      # from the ISO's offline mirror (first boot with network: deferred)

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
| `desktop.theme` | `omarchy-theme-set`, headless, as the user, after user setup |
| `desktop.agent` | Recorded in `~/.local/state/omarchy/first-run-agent`. Installing an agent needs a network and the user's own tools (mise), so Omarchy's first-login setup (an `omarchy` fork change) offers it with a notification that installs it on click. |
| `packages.extra` | Installed from the offline mirror, next to the runtime packages |
| everything else | Maps 1:1 onto what the configurator already writes |

- The filesystem stays btrfs, the bootloader stays Limine, and the subvolume layout is unchanged.
- `/home` on a second disk only affects the `@home` subvolume. It moves off the root disk and onto its own disk. Snapshots and factory reset still cover `/`.

### 4.3 Validation rules

**`chefs-kitchen validate`** (static, no hardware access):
- It rejects plaintext secrets. Every secret (`users.password`, `encryption.passphrase`, `network.tailscale_authkey`) accepts `{ insecure_plaintext = "…" }`, which prints a warning in every mode.
- It rejects unknown keys. A typo must never be silently ignored.
- Username and hostname follow the wizard's own rules (`setup-form.sh`).
- `same_as_user` with only a `password_hash` warns that the install can't run with `--yes`.
- `provisioning.defer = true` rules out `[[users]]`, `encryption.passphrase` and `[desktop]`.
- `theme`, `agent` and `packages.extra` are checked by `plan`, not `validate`. The ISO knows them, and `validate` runs anywhere: the ISO build records the bundled runtime's themes and agents in `/usr/share/omarchy-iso/`, and `packages.extra` is resolved, dependencies included, against the offline mirror.

**`chefs-kitchen plan`** (probes hardware; `--yes` applies the unattended rules):
- **Target disk.** `target` must resolve to **exactly one** disk. That disk must never be the install medium or a `cidata` drive, and must be at least ESP + 32 GiB.
- **Home disk.** `home.disk` must resolve to a different disk than `target`, of at least 8 GiB. It gets its own "What dies" block, and in interactive mode its own typed confirmation. It isn't supported with `mode = "free-space"`.
- **Free space.** The largest free region must fit a 2 GiB ESP and 32 GiB, and no partition may be BitLocker-encrypted. Nothing is erased, so `on_existing_data` doesn't apply. `expect_fingerprint` still does.
- **`on_existing_data = "abort"`** is the unattended default. If either disk has any signature, the install stops, prints the wipe table and hints at the two ways forward.
- **`expect_fingerprint`** is a sha256 over the partition-table type plus, for each partition, its start, size, type GUID and filesystem UUID. `chefs-kitchen plan` prints the current value so it can be pasted into the config. It is the unattended equivalent of "yes, *that* drive, with *that* data on it".

### 4.4 Implementation

**Compiler shim.** `chefs_kitchen_config` is a Python package: stdlib `tomllib` plus dataclasses, so no new dependencies. It turns the TOML into **today's** `user_configuration.json`, `user_credentials.json` and flag files. The orchestrator therefore runs unchanged, except for the swap and home branches above. Reading the plan directly can come later, once the shim has proved itself.

**Files touched:**

| File | Change |
|---|---|
| `omarchy-iso/configs/airootfs/usr/share/omarchy-iso/chefs_kitchen_config/` | **New.** `schema.py`, `resolve.py` (disk selectors via `/dev/disk/by-id` and `lsblk -J`), `plan.py` (wipe table and fingerprint), `compile_archinstall.py`, `helpers.py` (calls the Bash disk helpers, so the wizard and `chefs-kitchen` share one implementation) |
| `…/usr/share/omarchy-iso/free-space.sh` | **New.** The free-space region analysis and partitioning, moved out of the configurator: the wizard decides, `chefs-kitchen` partitions |
| `…/usr/share/omarchy-iso/wizard-toml.sh` | **New.** The wizard's answers as `install.toml` |
| `…/usr/local/bin/chefs-kitchen` | **New** dispatcher |
| `…/usr/local/bin/omarchy-iso-run` | **New.** The dashboard and orchestrator launch, moved out of `.automated_script.sh`, so every path starts installs the same way |
| `…/usr/local/bin/omarchy-cidata-load` | Also accept `install.toml` (exit 10), which wins over the legacy pair |
| `…/root/.automated_script.sh` | cidata → `chefs-kitchen install --config … --yes --no-launch`, then `omarchy-iso-run` |
| `…/root/configurator` | Write `install.toml`. Remove the direct JSON writers and the Ctrl+C toggle. Add the wipe summary and "Load from USB". |
| `orchestrator/` | Swap-strategy skip in `configure_hibernation`. `/home` disk mount and crypttab. Theme and agent (`configure_desktop`). Extra packages. Copy the stripped `install.toml` to the target (`record_install_toml`). `validate_boot` encryption assertion in both directions, and the `/home` disk's fstab, crypttab and key. |
| `builder/build-iso.sh` | Record the bundled runtime's themes and agents for `plan` |
| `omarchy/install/user/first-run/chosen-agent.sh` | **New.** Offer the agent chosen in `install.toml` at first login |
| `omarchy/manual/51-unattended-installs.md` | Rewrite around `install.toml` |
| `omarchy-iso/bin/omarchy-iso-test` | Its wizard scenarios now install through `install.toml`, since the wizard writes one. TOML-fixture scenarios are still to do: the harness needs an Omarchy host, and rows E–J were run by hand in QEMU. |

---

## 5. Change #1: signed boot as a post-install command

### 5.1 Why post-install, not in the installer

**The USB can't boot with Secure Boot on.** Without a Microsoft-signed shim (months of `shim-review`), the stick can't boot with Secure Boot enforcing on factory keys, whatever the installer does.

**The installed system is the right place.** Putting Secure Boot into Setup Mode, enrolling your own keys and signing the boot chain is something the installed system can do as well as the installer. It is also far easier to recover from if it goes wrong, because the machine already boots.

**It stays separate from the install path.** Keeping signed boot out of the installer means no orchestrator phase changes for it, and a signing failure can never take down a fresh install.

### 5.2 Command

This follows Omarchy's convention: `bin/omarchy-secureboot-*` with `omarchy:summary` headers, exposed as `omarchy secureboot <verb>`. Each is a thin wrapper that runs the vendored engine (§5.3) with `sudo`.

```
omarchy secureboot enable     # guided, one firmware step per run: keys → seal and sign → delete PK → append-enroll → turn SB on
omarchy secureboot status     # firmware, keys, settings, loader seal and signatures, hook and watchers; ends with the fix (--quiet: exit status)
omarchy secureboot sign       # the converge-and-verify pass the hook and watchers run; safe at any time
omarchy secureboot disable    # back to stock (SB must be off first); keys stay
omarchy secureboot windows preflight|setup|remove|status|bootnext
```

### 5.3 Engine and `enable` flow

The engine is [OmaSecBoot](https://github.com/peregrinus879/omasecboot) (MIT), vendored by `bin/omarchy-dev-vendor-secureboot <commit>`: a scripted copy plus ordered renames, never hand-edited, so an upstream fix is a pin bump. It lands in `install/secureboot/` (ships in the omarchy package at `/usr/share/omarchy/install/secureboot`), its hermetic suites in `test/secureboot/` (run by `test/shell.d/secureboot-test.sh`), and its design documents verbatim in `docs/secureboot/`. `install/secureboot/VENDORED` records the pin and the rules.

**Design (supersedes the original §5.3, decided 2026-09-26).**

1. **Prerequisites.** x86_64, UEFI, Limine, UKIs, a vfat ESP; `sbctl` and `efibootmgr` are installed by `enable` (both are in the ISO's offline list).
2. **Keys.** `sbctl create-keys`; keys stay in `/var/lib/sbctl` on the encrypted root.
3. **Seal, don't hash.** `ENABLE_ENROLL_LIMINE_CONFIG=yes` (only honoured in `/etc/default/limine`) and `ENABLE_VERIFICATION=no` in `/etc/default/limine`, originals recorded for `disable`. Limine seals the loader over `limine.conf`; UKIs are EFI loads the firmware checks by signature, so path hashes are not needed and would go stale when a file is signed.
4. **Sign.** The loader and every UKI, and anything else on the ESP that arrives unsigned. **Never** snapshot images (limine-snapper-sync stores their hashes; signing would break them for good; snapshots taken after setup copy signed UKIs) and never the fallback loader (it stays raw as the rescue path with SB off).
5. **Hook and watchers, never failing an update.** A Limine post-hook `90-omarchy-secureboot-sign` runs `sign --quiet || :` at the end of every Limine operation. Two instances of `omarchy-secureboot-watch@.path` re-seal on edits to `limine.conf` and when the loader is replaced (Omarchy's `99-omarchy-limine.hook` copies a raw loader after Limine upgrades). Failures are repaired or reported, never fatal to pacman. `omarchy-secureboot-integrate` writes the hook and units into `/etc` with the engine's absolute path, and refuses when the engine isn't root-only (a dev checkout in `$HOME`), because they run as root.
6. **Firmware, one step per run.** Back up PK/KEK/db/dbx to `/var/lib/omarchy-secureboot/firmware-backup/`, then ask the user to delete **only the PK** and save with SB disabled. Next run, in Setup Mode: **append** your certificates to KEK and db (`sbctl enroll-keys --append --partial`, db, KEK, then PK), each read back. Microsoft's and the vendor's certificates stay, which covers discrete-GPU option ROMs without `--microsoft`. dbx is never written. Firmware that clears every key is detected and offered a rebuild from yours, Microsoft's and the built-in defaults; a partial clear is refused.
7. **Turn SB on.** The next run tells the user to; `status` proves the result.
8. **Dual boot.** `windows setup` adds a Limine entry using the `efi_boot_entry` protocol (restart into the firmware's Windows Boot Manager, not a chainload), and `windows bootnext` sets BootNext once, both keeping Limine out of BitLocker's measurements. `windows preflight` finds BitLocker volumes first. Menu: System > Reboot to Windows.
9. **Updates.** `omarchy update` runs `omarchy-update-secureboot`: refresh the hook and units, run `status --quiet`, and print a red line on failure. It never fails the update.

### 5.4 Docs

| File | Change |
|---|---|
| `omarchy/manual/02-getting-started.md:7` | Shipped with Phase 2: "Secure Boot has to be off to boot the installer. Once Omarchy is installed, `omarchy secureboot enable` turns it back on with keys owned by your machine … Leave the TPM alone: nothing needs it disabled." It doesn't offer Setup Mode, as an earlier draft did: firmware left in Setup Mode has no vendor keys to keep, so `enable` would then take the rebuild path instead of appending. |
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
| `packages.extra` from the network at first boot | New first-boot machinery; the offline mirror covers the common case | A package people want that the mirror doesn't carry |
| More than one `[[users]]` | The wizard and orchestrator create one user | A real multi-user machine |

---

## 7. Phases and tests

| Phase | Contents | Exit criteria |
|---|---|---|
| **0** | §2 wipe summary and picker fixes. §3 visible encryption choice. | Rows A–D |
| **1** | §4 TOML: validate, plan, install. Compiler shim. cidata TOML. Wizard writes TOML. `/home` disk and swap branches. Theme, agent, extra packages. | Rows E–J, plus every existing `omarchy-iso-test` scenario passing from TOML |
| **2** | §5 `omarchy secureboot`, which runs on installed systems and is independent of the ISO. §5.4 docs, including line 7. | Rows K–N, plus hardware |

The rows ran by hand in QEMU plus OVMF, with the helpers in `omarchy-kitchen/scripts/qemu/`. `bin/omarchy-iso-test` needs an Omarchy host and hasn't been run yet, which leaves part of Phase 1's exit criterion open. OVMF vars without enrolled keys start in Setup Mode.

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
| K | Installed VM with vendor keys, `omarchy secureboot enable` run by run (delete PK, enroll, turn SB on) | Enrolled, vendor keys kept. Boots with SB enforcing. `status` clean; `sbctl verify` clean except the raw fallback loader, by design. |
| L | Flip a byte in the UKI on the ESP | Firmware refuses it |
| M | Edit `limine.conf` on the ESP from outside the running system (offline image) | Limine refuses (checksum mismatch). A hand edit on the running system is re-sealed by the watcher instead. |
| N | Kernel update plus new snapper snapshot | New UKI signed, loader re-sealed, and the new snapshot boots with SB on. Snapshots from before `enable` stay unsigned and are refused. Reboots cleanly. |

**Hardware for Phase 2:**
- one desktop with a discrete GPU, to prove that the appended enrollment keeps its option ROM starting
- one laptop with Windows and BitLocker, to test the BootNext path. Deferred on 2026-09-26 until a laptop is procured. It stays an exit criterion, so the upstream PRs wait for it.

---

## 8. Open questions

1. ~~**Limine config-enrollment key.**~~ Answered 2026-09-26: `ENABLE_ENROLL_LIMINE_CONFIG=yes`, honoured only in `/etc/default/limine`. `limine-snapper-sync` goes through the same post-hooks, so the hook re-seals after every snapshot sync. See `omarchy/docs/secureboot/upstream-contracts.md` C2 and C3.
2. ~~**Microsoft 2023 CAs.**~~ Answered 2026-09-26: sbctl 0.18 ships all seven 2011 and 2023 certificates. The append path writes none of them and keeps what the firmware holds. `enable` warns before the PK is deleted when KEK lacks the 2023 KEK CA, because afterwards only the new PK owner can add it; `status` names any 2023 certificate missing. See C9.
3. ~~**Vendor vs. write.**~~ Decided 2026-09-25: vendor OmaSecBoot (MIT) into the `omarchy` fork at a pinned commit, with attribution. Keep its enrolment, BootNext and firmware workarounds close to upstream so fixes cherry-pick cleanly, and reshape the command layer into `omarchy secureboot`. See `docs/decisions.md`.
4. ~~**Upstreaming.**~~ Decided 2026-09-25: upstream PRs wait until all phases are done. Upstreamable work stays on topic branches from `quattro` until then.
5. ~~**Name.**~~ Decided 2026-09-25: Chefs Kitchen, CLI `chefs-kitchen`.

## Sources

- Omarchy source: `omacom/omarchy`, `omarchy-iso`. File and line references are from the 2026-09-25 HEAD.
- Upstream plan: `omarchy-iso/plans/consumer-secure-boot.md`
- Limine Secure Boot semantics: https://github.com/limine-bootloader/limine/blob/trunk/USAGE.md
- Working Omarchy + sbctl + Limine reference, now OmaSecBoot and vendored for Phase 2: https://github.com/peregrinus879/omasecboot
- sbctl: https://man.archlinux.org/man/sbctl.8
