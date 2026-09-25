# Omarchy "The Kitchen Is Open": Installer Spec

**Status:** Draft v1 · 2026-09-25
**Base:** `omacom/omarchy` (formerly `basecamp/omarchy`) 4.0.0.alpha and `omarchy-iso` (both at HEAD on 2026-09-25)
**Scope:** Design only. No code is written yet.

> **Naming placeholder.** This doc calls the fork **Kitchen** and its CLI `kitchen`. The product name is "Omarchy: The Kitchen Is Open". Renaming is one search-and-replace.

---

## 0. The five changes at a glance

| # | Change | Size | Depends on | Ships in |
|---|--------|------|------------|----------|
| 4 | Last-chance wipe summary | S | none | Phase 0 |
| 5 | Encryption becomes a visible choice (still the default) | S | none | Phase 0 |
| 3 | `kitchen install --config install.toml` as the headline install path | M | none | Phase 1 |
| 2 | "Custom" screen: filesystem, swap, encryption, separate `/home` | M–L | #3 (the screen edits the same model) | Phase 2 |
| 1 | Signed boot (sbctl, own keys) and TPM2-backed unlock | L | systemd initramfs migration (Phase 3) | Phases 3–5 |

**One design decision ties the five together:** *the TOML file is the installer's only input.* The wizard, the Custom screen, cidata autoinstall and the CLI all produce the same `InstallPlan`. The wipe summary is a rendering of that plan. The orchestrator executes it. Nothing reaches the disk that isn't in the plan.

---

## 1. What upstream does today

These facts come from reading the code. They matter because several of the five problems are partly solved already, just hidden.

**Flow.**
- `root/.automated_script.sh` tries `omarchy-cidata-load` first.
- If no cidata drive loads, it runs `root/configurator`, a bash/gum wizard of about 1,250 lines.
- The configurator writes these files to `/root`:
  - `user_configuration.json` (archinstall format, plus an `omarchy_install` block)
  - `user_credentials.json`
  - loose `*.txt` flag files
- `omarchy-iso-install` then runs `python -m orchestrator.main`. This is 14 phases in `orchestrator/phases_impl.py` that use archinstall **as a library** (tested against archinstall 4.4).

**Secure Boot and TPM.**
- There are no checks anywhere in the installer.
- The ISO uses `bootmodes=('bios.syslinux' 'uefi.grub')` with unsigned GRUB (`configs/profiledef.sh`).
- `manual/02-getting-started.md:7` tells users to turn off Secure Boot "and/or TPM".
- Two things already exist:
  - The installed system **already boots a UKI** through Limine (`finalize_limine_boot`).
  - A detailed shim+MOK plan exists in `plans/consumer-secure-boot.md`. It explicitly excludes TPM unlock from v1.

**Initramfs.**
- `HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs)`.
- This is a **busybox `encrypt` initramfs**, which cannot do TPM2 unlock.
- The orchestrator already writes `/etc/crypttab.initramfs` in protected mode. Only `sd-encrypt` reads that file, so today it is dead code.

**Encryption.**
- Encryption is on by default. It is *not* strictly mandatory: pressing **Ctrl+C on the confirm screen** toggles "install without encryption" (`confirm_disk_overwrite`, `configurator:949`). That makes it a secret handshake, not a choice.
- The LUKS passphrase is always the login password.
- The flag file `user_encrypt_installation.txt` does not control encryption. It controls SDDM autologin and one `validate_boot` assertion. It must be kept in sync with the JSON by hand.

**Disk layout.**
- Btrfs is hardcoded, with subvolumes `@ @home @log @pkg`, a 2 GiB ESP and `compress=zstd`.
- There is no separate `/home` and no filesystem choice.
- Swap is always zram **plus** a RAM-sized btrfs swapfile for hibernation (`configure_hibernation` → `omarchy-hibernation-setup`), with no way to opt out.
- The full-disk path has no minimum-size check. `main_partition_size` can go negative.

**Wipe confirmation.**
- The picker line looks like `/dev/nvme0n1 (476.9G) - Samsung … [vfat, ntfs, ext4(/mnt)]`.
- The confirm screen says: "Everything will be overwritten. There is no recovery possible. **Confirm overwriting /dev/XXX** [Yes, install] / [No, change it]."
- There are no partition sizes, labels or OS names, and no serial number. Two identical NVMe drives render identically.
- Latent bugs in the same code:
  - The `cidata` drive is **not excluded** from the picker. If a cidata drive is present but invalid, the wizard runs and offers that drive as a wipe target.
  - `lsblk -r` whitespace parsing shifts columns when FSTYPE is empty.

**Autoinstall.**
- A drive labelled `cidata` holding `user_configuration.json` and `user_credentials.json` skips the wizard.
- Validation checks only that the files exist.
- The LUKS passphrase is stored in plaintext inside the JSON.
- An encrypted autoinstall still needs a human at first boot to type the passphrase.

---

## 2. Architecture: config first, wizard second

```
                  ┌──────────────┐
  wizard (gum) ──▶│              │
  Custom screen ─▶│ install.toml │──▶ kitchen-plan ──▶ InstallPlan ──┬──▶ wipe summary (#4)
  cidata drive ──▶│  (v1 schema) │    (validate,                     ├──▶ --plan / --dry-run output
  CLI --config ──▶│              │     resolve disks,                └──▶ orchestrator phases
                  └──────────────┘     probe firmware)                     │
                                                                           ▼
                                                     /etc/kitchen/install.toml (secrets stripped)
                                                     /etc/kitchen/install.lock.toml (resolved facts)
```

### Components

| Component | Language | Location | Job |
|---|---|---|---|
| `kitchen` CLI | bash dispatcher | `/usr/local/bin/kitchen` (ISO) | `install`, `plan`, `validate`, `config export` |
| `kitchen_config` | Python (stdlib `tomllib`, dataclasses) | `usr/share/omarchy-iso/kitchen_config/` | Parse, validate, apply defaults, resolve disk selectors, emit `InstallPlan` JSON |
| Compiler shim | Python | same package | `InstallPlan` → today's `user_configuration.json` + `user_credentials.json` + flag files, so the orchestrator runs unchanged in Phase 1 |
| Configurator | bash/gum | `root/configurator` | Asks questions, **writes `install.toml`**, then calls `kitchen install --config /root/install.toml --interactive` |
| Orchestrator | Python | existing | Phase 1 reads the compiled JSON. From Phase 2 on it reads `InstallPlan` directly and the compiler shim is deleted. |

**Why Python for the model:** the orchestrator is already Python, and `tomllib` ships in the stdlib (the ISO runs Python 3.14). The model therefore adds no new dependency. Bash stays for the UI, where gum already lives.

---

## 3. Change #3: declarative, reproducible installs

### 3.1 Commands

```
kitchen install --config install.toml            # interactive: shows wipe summary, asks for confirmation
kitchen install --config install.toml --yes      # unattended: guarded by [disk].on_existing_data
kitchen plan    --config install.toml            # prints the resolved plan and wipe summary, touches nothing
kitchen validate install.toml                    # schema + semantic checks, no hardware probing (CI-friendly)
kitchen config export > install.toml             # on an installed system: reproduce this machine
```

**Config sources, checked in this order:**
1. `--config PATH`
2. `install.toml` on a drive labelled `cidata`
3. `kitchen.config=URL` on the kernel command line (Phase 2+, only when networking is up)
4. Legacy cidata JSON pair (still accepted; converted to TOML with a deprecation warning)
5. The wizard

**Every clicked install is also a described install.** The wizard writes `install.toml`. The installer copies it, with secrets stripped, to `/etc/kitchen/install.toml` on the target. `kitchen config export` prints it back out.

### 3.2 Schema v1

```toml
schema = 1

[system]
hostname = "marvin"
timezone = "America/Toronto"
keyboard = "us"
locale   = "en_US.UTF-8"

[[users]]
name          = "kevin"
full_name     = "Kevin"
email         = "…"                            # optional, feeds git config
password_hash = "$6$…"                         # openssl passwd -6; plaintext is not accepted here
groups        = ["wheel"]
ssh_authorized_keys = ["ssh-ed25519 AAAA… kevin@laptop"]

[disk]
# Never "/dev/nvme0n1". Kernel enumeration order is not stable across boots or firmware updates.
target = { by_id = "nvme-Samsung_SSD_980_PRO_500GB_S69ENX0T812345" }
# Other selectors: { serial = "…" }, { wwn = "…" }, { model = "…", size = "465.8GiB" },
#                  { path = "/dev/vda" } (VMs only; warns on bare metal)
mode = "wipe"                                   # "wipe" | "free-space"
on_existing_data = "abort"                      # "abort" | "wipe"; unattended default is "abort"
# expect_fingerprint = "sha256:…"               # optional: wipe only if the partition table still
                                                # matches (see `kitchen plan` output)

[disk.layout]
esp_size   = "2GiB"
filesystem = "btrfs"                            # "btrfs" | "ext4" | "xfs"
home       = "same"                             # "same" | "partition" | "disk"
# home_size = "300GiB"                          # when home = "partition"
# home_disk = { by_id = "nvme-…S69ENX0T899999" }  # when home = "disk"
# home_reuse = false                            # true = mount an existing /home, don't format it

[swap]
strategy    = "zram+hibernate"                  # "zram+hibernate" | "zram" | "partition" | "file" | "none"
zram_size   = "ram"
# size      = "32GiB"                           # for partition/file; defaults to RAM size

[encryption]
enabled   = true
unlock    = "tpm2"                              # "passphrase" | "tpm2" | "tpm2+pin"
# Passphrase source. Pick exactly one:
passphrase = { same_as_user = "kevin" }         # default; matches today's behaviour
# passphrase = { prompt = true }                # ask at install time (interactive only)
# passphrase = { file = "luks.pass" }           # relative to this TOML (cidata)
# passphrase = { env = "KITCHEN_LUKS" }
keep_passphrase_slot = true                     # keep passphrase as fallback after TPM enrollment
recovery_key = { show = true }                  # or { age_recipient = "age1…" } for unattended

[boot]
secure_boot = "auto"                            # "auto" | "require" | "off"
microsoft_keys = true                           # sbctl -m: GPU option ROMs, Windows, firmware drivers
bootloader  = "limine"                          # "limine" | "systemd-boot"

[desktop]
theme = "tokyo-night"
agent = "claude"                                # any name `omarchy-default-agent` accepts

[packages]
extra = ["obs-studio", "blender"]               # installed from the offline mirror if present,
                                                # otherwise at first boot with network
remove = []

[network]
tailscale_authkey = { file = "tailscale.key" }

[provisioning]
defer = false                                   # true = "prepare for another owner"
```

### 3.3 Semantic rules

`kitchen validate` enforces these. `kitchen plan` adds hardware-dependent checks.

- `encryption.unlock = "tpm2*"` requires `encryption.enabled = true`. At plan time it also requires a TPM 2.0 (`systemd-analyze has-tpm2`). If there is no TPM, the plan says so and falls back to `passphrase` in interactive mode; unattended mode **fails**.
- `boot.secure_boot = "require"` makes the plan fail unless the firmware is in Setup Mode (see §6.2).
- A non-btrfs filesystem disables snapper, `limine-snapper-sync`, the `@factory` snapshot and factory reset. The plan lists these as **"You lose:"** lines rather than silently skipping them.
- `swap.strategy` containing `hibernate` requires swap ≥ RAM. The plan prints the computed size.
- `mode = "wipe"`: disk size must be ≥ ESP + 32 GiB. This fixes the negative `main_partition_size` bug.
- Plaintext secrets are rejected. The one exception is `passphrase = { insecure_plaintext = "…" }`, which prints a warning in every mode.
- `[disk].target` must resolve to **exactly one** disk. Neither the install medium nor any `cidata` drive can ever be a target (this fixes the upstream bug).

### 3.4 Reproducibility, stated honestly

"Rebuildable from a text file" means: **the same ISO version plus the same `install.toml` gives the same machine.** That covers the same layout, packages, theme, agent, users and security posture. The differences are:
- UUIDs, keys and machine-id, which must differ
- anything installed after first boot

`/etc/kitchen/install.lock.toml` records:
- the ISO version
- the resolved disk (by-id and serial)
- the offline-mirror package set hash
- the firmware Secure Boot state at install time
- the enrolled unlock methods

`kitchen plan` against a lock file reports drift, for example "this ISO ships linux-omarchy 7.2.1, lock says 7.1.9".

The 35-second install time is a property of the offline mirror, not of this design. This spec keeps it, but does not promise any particular time.

### 3.5 Files touched

| File | Change |
|---|---|
| `omarchy-iso/configs/airootfs/usr/share/omarchy-iso/kitchen_config/` | **new**: `schema.py`, `resolve.py` (disk selectors via `/dev/disk/by-id`, `lsblk -J`), `plan.py`, `compile_archinstall.py`, `export.py` |
| `…/usr/local/bin/kitchen` | **new** dispatcher |
| `…/usr/local/bin/omarchy-cidata-load` | Also accept `install.toml`. Keep the JSON path. |
| `…/root/.automated_script.sh` | cidata → `kitchen install --config … --yes`; otherwise the wizard |
| `…/root/configurator` | Write `install.toml` instead of three JSON/txt files. This is the biggest diff in Phase 1, but it is mostly deletion. |
| `orchestrator/context.py` | Phase 2: `InstallContext.from_plan(plan)` replaces `from_env` file-juggling. `ctx.encrypt` comes from the plan, so the flag file disappears. |
| `omarchy/manual/51-unattended-installs.md` | Rewritten around `install.toml`. Promoted to chapter 2 in the manual order. |
| `omarchy-iso/bin/omarchy-iso-test` | Add TOML fixtures: one per Custom-screen combination. |

---

## 4. Change #4: last-chance wipe summary

This is the cheapest change and the one with the most value. It ships first and is independent of everything else.

### 4.1 Interactive screen

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
   1  2 GiB      vfat   ESP           /boot
   2  463.8 GiB  LUKS2 → btrfs        / (@, @home, @log, @pkg) · zram + 32 GiB swapfile
   Unlock: TPM2 (Secure Boot enforced) · passphrase fallback · recovery key

  Type  nvme1n1  to erase this disk, or press Esc to go back
  > _
```

### 4.2 Rules

- **Data sources.** Use `lsblk -J -b -o NAME,PATH,SIZE,FSTYPE,LABEL,PARTLABEL,PARTTYPE,MODEL,SERIAL,TRAN,MOUNTPOINTS`, which is JSON and fixes the `-r` column-shift bug. Add `blkid -p` and `wipefs -n`.
- **"What's on it" probes.** All probes are read-only and best-effort. A timeout yields "—", never a failed screen.
  - **ESP:** mount `-o ro` and look for `EFI/Microsoft`, `EFI/limine`, `EFI/systemd`, `EFI/*/grubx64.efi`.
  - **BitLocker:** reuse the existing `-FVE-FS-` probe.
  - **LUKS:** `cryptsetup luksDump` for the label and the "Omarchy/Kitchen" header token. Never attempt to unlock.
  - **ext4, btrfs, xfs, ntfs:** mount `ro,noload` (ntfs3 with `ro`) and read `etc/os-release`, `@/etc/os-release` and used space. Skip this if the partition is already mounted.
- **Typed confirmation.**
  - Required when `wipefs -n` finds **any** signature on the target.
  - The user types the kernel name (`nvme1n1`). Typing forces the user to read the screen. The "What's on it" column is what tells two identical drives apart.
  - A blank disk gets a plain Yes/No.
- **"Not touched" list.** This is always shown when more than one disk is present. The most common way to wipe the wrong drive is choosing between two drives that look the same, and this list shows the user the drive they *didn't* pick.
- **Mounted partitions.** If any target partition is mounted or used as swap, the screen shows it in red and refuses to continue until it is released. Today this is handled silently by `omarchy-iso-cleanup-disk`.
- **Free-space mode.** The same screen is used, but "What dies" becomes "Nothing is erased". The screen also shows which free region gets used and what is kept.
- **Unattended mode.**
  - `kitchen plan` prints the same table to stdout.
  - `kitchen install --yes` prints it to the install log and the dashboard.
  - If the target has signatures and `on_existing_data = "abort"`, the install stops with the table and a hint: `on_existing_data = "wipe"` or `expect_fingerprint = "sha256:…"`.
  - The fingerprint is a sha256 over (partition table type, and per partition: start, size, type GUID, fs UUID). It is the unattended equivalent of "yes, *that* drive, with *that* data on it".

### 4.3 Also fix in the same PR

- Exclude every `cidata`/`CIDATA`-labelled disk from the picker. This is today's bug.
- Exclude `mmcblk*boot*` and `mmcblk*rpmb` devices.
- Add serial and "what's on it" to the **picker** lines, not only to the final screen. Two identical 512 GB NVMe drives must not render identically anywhere.

---

## 5. Change #5: encryption is the default, not a mandate

### 5.1 UX

Replace the hidden Ctrl+C toggle with a visible choice. In Omakase mode this is one line in the plan summary. In Custom mode it is a field.

```
  Disk encryption
  > Encrypted, unlock with TPM (recommended)    boots silently on this machine; asks for
                                                a recovery key if the disk moves or boot is tampered
    Encrypted, type a passphrase at boot        works without TPM or Secure Boot
    Encrypted, TPM + PIN                        strongest; short PIN instead of a passphrase
    Not encrypted                               for servers, VMs, or machines whose data lives elsewhere
```

- **Default.** "Encrypted" in every case. The TPM option is the default only when §6 finds a usable TPM *and* Secure Boot will be enforced. Otherwise the default is "type a passphrase".
- **Chassis hint.** When `/sys/class/dmi/id/chassis_type` is a portable type (8, 9, 10, 14, 30, 31, 32) and the user picks "Not encrypted", one line appears: *"This looks like a laptop. If it's lost or stolen, anyone can read the disk."* There is no second confirmation, because the user said no and that is their call.
- **Headless note.** For headless boxes, "Encrypted, unlock with TPM" usually removes the friction that motivates "Not encrypted". The UI text says so once and does not push further.
- **Passphrase source.** Whenever a passphrase is involved, Custom mode offers "Use my login password" (the default, as today) or "Set a separate disk passphrase".

### 5.2 Fix the coupling encryption brings with it

Today `configure_login` turns on SDDM autologin when `ctx.encrypt` is true, on the theory that "the LUKS prompt is the auth boundary". With TPM unlock there *is* no LUKS prompt, so keeping that rule would boot a stolen laptop straight to the desktop.

**New rule.** Autologin is on only when booting requires a human secret:

| Unlock method | LUKS prompt at boot | SDDM autologin |
|---|---|---|
| passphrase | yes | **on** (today's behaviour) |
| tpm2+pin | PIN | **on** |
| tpm2 | none | **off**: SDDM is the auth boundary |
| not encrypted | none | **off** (today's behaviour) |

Implementation:
- `configure_login` reads `plan.encryption.unlock`, not `ctx.encrypt`.
- `validate_boot` asserts the combination.
- The hypridle/hyprlock config must lock **before** suspend and hibernate when unlock is `tpm2`. A resumed hibernation image is otherwise the same stolen-laptop hole.

### 5.3 Other follow-through

- `validate_boot`'s `cryptdevice=` check becomes "LUKS configured iff `plan.encryption.enabled`". This is expressed against `crypttab.initramfs`, after the Phase 3 migration.
- Remove `user_encrypt_installation.txt` from the cidata contract. It is still accepted in legacy mode.
- `README.md` §Autoinstall no longer needs the "the flag file must match it" warning.

---

## 6. Change #1: signed boot and TPM2 unlock

### 6.1 The honest version of the claim

A fork without a Microsoft-signed shim cannot make its **USB stick** boot on factory Secure Boot keys. That is the months-long `shim-review` path described in upstream's `consumer-secure-boot.md`. What the fork *can* do is better for the installed machine:

- **The ask changes** from "turn off Secure Boot" to **"put Secure Boot in Setup Mode"**. On most firmware this is one menu item: "Reset to Setup Mode" or "Clear Secure Boot keys".
- **The installer enrolls machine-owned keys**, plus Microsoft's keys so GPU option ROMs and Windows keep working.
- **It signs everything it boots, and the machine comes up with Secure Boot enforcing.** Only binaries signed by *this machine's* key (or Microsoft's, if kept) will run. That is a tighter policy than a stock shim distro.
- **TPM never needed disabling.** Delete that sentence from the manual.
- **VMs are the easy case.** Proxmox and OVMF with `pre-enrolled-keys=0` already *is* Setup Mode, so unattended VM installs get signed boot for free.

### 6.2 Firmware state detection

This happens at plan time, in the live ISO. Read the efivars `SecureBoot-8be4df61-…` and `SetupMode-8be4df61-…` (or `sbctl status --json`), plus `systemd-analyze has-tpm2`.

| Firmware state | Omakase behaviour | `secure_boot = "require"` |
|---|---|---|
| UEFI, **Setup Mode** | Enroll keys, enforce. Nothing to ask. | proceed |
| UEFI, SB off, vendor keys present (user mode) | Screen: *"Signed boot is one reboot away."* Offers [Reboot to firmware setup] (`systemctl reboot --firmware-setup`), with per-vendor hints for the menu item, or [Install without signed boot]. The second is recorded in the lock file, and `kitchen secureboot enable` can do it later. | fail with the same text |
| UEFI, SB **on** | Impossible: the unsigned ISO would not have booted. Log it if seen. | n/a |
| BIOS / CSM | No Secure Boot. TPM unlock is unavailable (no PCR 7 policy worth binding). Passphrase default. | fail |

The per-vendor hint table is data (`secureboot-vendors.toml`), keyed on `/sys/class/dmi/id/sys_vendor` and `board_vendor`, covering ASUS, Gigabyte, MSI, ASRock, Dell, Lenovo, HP and Framework. For example, on ASUS AM5 boards the path is Boot → Secure Boot → Key Management → "Clear Secure Boot Keys".

### 6.3 Boot chain

```
Firmware (Secure Boot, user mode, db = {machine key, Microsoft UEFI CA})
  └─ EFI/limine/limine_x64.efi    signed by machine db key; limine.conf BLAKE2b hash enrolled into the binary
      └─ protocol: efi → EFI/Linux/omarchy_<kernel>.efi   UKI signed by machine db key,
                                                          verified by firmware LoadImage
          └─ systemd-stub: embedded cmdline is authoritative under SB; measures to PCR 11
              └─ systemd initramfs → sd-encrypt → TPM2 unseal (PCR 7 + PCR 15) → root
```

**Why Limine stays (for now).**
- Limine keeps snapshot boot, which is Omarchy's rollback story.
- Its Secure Boot model is workable. Once a config checksum is enrolled into the Limine EFI binary, Limine refuses a modified `limine.conf` and requires hashes on every path it loads itself. The one exception is EFI chainloads, which go through the firmware's own signature verification. The UKI entries are EFI loads, so they must be sbctl-signed, and they are.
- A community project has shown this working on Omarchy: `peregrinus879/omarchy-secureboot`.
- **Fallback:** `boot.bootloader = "systemd-boot"`, which is the path upstream's plan prefers. It is kept selectable in case Limine's enforcement turns out to be fragile on real hardware.

**Limine hardening when Secure Boot is enforced:**
- `hash_mismatch_panic: yes`. The upstream template has `no`.
- Set the config editor off explicitly.
- Re-enroll the config hash and re-sign `limine_x64.efi` after every `limine-update` and `limine-snapper-sync` run. Every config regeneration invalidates the enrolled hash, so this is the part that bricks boots when it's missing.

### 6.4 Install-time steps

These are new orchestrator phases, run after `finalize_limine_boot` and before `validate_boot`, in the chroot.

1. `sbctl create-keys`. Keys land in `/var/lib/sbctl` on the **encrypted** root and never on the ESP.
2. Enroll the `limine.conf` hash into `limine_x64.efi` (via limine-entry-tool's config-enrollment setting; confirm the exact key against the shipped `limine-mkinitcpio-hook` version).
3. `sbctl sign -s` for `limine_x64.efi`, every UKI, and the fallback UKI.
4. `sbctl enroll-keys --microsoft`. `--microsoft` is the default and is required when a discrete GPU is present, because its option ROM (GOP driver) is Microsoft-UEFI-CA-signed, and without it the firmware can refuse to run it and you get no display. Add `--firmware-builtin` when `boot.microsoft_keys = true` on laptops. `--tpm-eventlog` is exposed as an expert flag only (sbctl marks it experimental).
5. Assert that `sbctl status` reports Setup Mode off and that `sbctl verify` shows every tracked file signed.
6. Install the pacman hook `zz-kitchen-secureboot.hook` (after `zz-sbctl.hook`) and a Limine post-hook that re-enrolls, re-signs and signs new snapshot UKIs (`*.efi_sha256_*`, `*.efi_b3_*`).
7. Dual boot: register Windows as a **firmware BootNext** entry rather than a Limine chainload. Otherwise Limine's re-signed binary changes Windows' TPM measurements and triggers BitLocker recovery.

**Failure policy.** This mirrors upstream's plan: never replace a bootable signed UKI with an unsigned one. If signing fails, keep the previous UKI and fail the pacman transaction loudly.

### 6.5 TPM2 unlock

**Prerequisite (Phase 3): switch to a systemd initramfs for all installs.**
```
HOOKS=(base systemd plymouth keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck <snapshot-overlay>)
```
- LUKS mapping moves from `cryptdevice=` on the cmdline to `/etc/crypttab.initramfs`, which upstream already writes; this makes that file live.
- Provisioning's `cryptkey=rootfs:/etc/omarchy/provisioning.key` becomes the crypttab keyfile field.
- `btrfs-overlayfs` is a busybox hook. **Verify** a systemd-initramfs equivalent in `limine-snapper-sync` before the migration, or port the hook. This is the main risk in Phase 3.
- Plymouth works with `sd-encrypt` through `systemd-ask-password`. Re-test the themed LUKS prompt and the `initramfs_async=0` workaround.

**Why enrollment happens at first boot, not install time.**
- During install the firmware is in Setup Mode, so PCR 7 holds a value it will never hold again.
- The TPM must therefore be enrolled after the first enforced boot.

**How it works:**
1. At install time, add a random **enrollment key** as a LUKS keyslot. Store it at `/var/lib/kitchen/tpm-enroll.key` (mode 0600, on the encrypted root). This is the same pattern upstream uses for deferred provisioning.
2. Also at install time, enroll a recovery key with `systemd-cryptenroll --recovery-key`.
3. On the first boot, the user types the passphrase once, or the recovery key in TPM-only mode.
4. `kitchen-tpm-enroll.service` then runs once. It is conditioned on:
   - `sbctl status` showing Secure Boot enabled, user mode, and our PK
   - a TPM2 being present
   - `/var/lib/kitchen/tpm-enroll.key` existing

   It runs:
   ```
   systemd-cryptenroll --unlock-key-file=/var/lib/kitchen/tpm-enroll.key \
     --tpm2-device=auto --tpm2-pcrs=7+15:sha256=0000000000000000000000000000000000000000000000000000000000000000 \
     [--tpm2-with-pin=yes]  /dev/disk/by-uuid/<luks>
   systemd-cryptenroll --wipe-slot=<enrollment slot> …   && shred -u /var/lib/kitchen/tpm-enroll.key
   ```
   It also sets `tpm2-device=auto,tpm2-measure-pcr=yes` in `crypttab.initramfs`.

**PCR choice and why:**

| PCR | What it binds | Why it's here |
|---|---|---|
| **7** | Secure Boot policy and the certificate that authorized each loaded image | With machine-owned keys, only images signed by *this* machine's db key (or Microsoft's) boot with this PCR 7 value. The certificate is measured, not the hash, so kernel updates and snapshot UKIs don't break unlock. |
| **15 = 0** | "No volume key has been measured yet this boot" | `tpm2-measure-pcr=yes` extends PCR 15 with the volume key right after unlock. The TPM therefore refuses a second unseal later in the same boot. This closes the swap-in-a-fake-root-partition attack. |
| 0, 2 | *not used* | These change on firmware updates, and their content is already covered via PCR 7 certificates (systemd-cryptenroll(1) advises against them). |
| 11 (signed policy) | *Phase 6* | A signed PCR 11 policy (ukify `--pcr-private-key`) would pin kernel+initrd per boot phase. It requires signing every snapshot UKI's policy too. It is deferred rather than shipped half-done. |

**Recovery flows:**
- **Firmware update, key change, or disk moved to another machine:** PCR 7 differs, the TPM refuses, and the user types the passphrase or recovery key. `kitchen tpm reenroll` re-seals with a fresh enrollment slot. The user never needs to touch cryptenroll flags.
- **Secure Boot turned off in firmware:** PCR 7 changes, so the passphrase or recovery key is required. This is intended.
- **Recovery key display:**
  - Interactive: shown at the end of the install as text plus a terminal QR code (`qrencode -t ansiutf8`). The user must confirm "I've saved it" before the reboot button activates.
  - Unattended: `recovery_key = { age_recipient = "age1…" }` writes only ciphertext to `ESP:/kitchen/recovery.age` and to the install log. Plaintext never leaves the installer.
- **`keep_passphrase_slot = false`** (TPM + recovery key only) is available in Custom mode and TOML. It is never the default.

### 6.6 Threat model in one paragraph

Protected:
- a stolen, powered-off machine (the disk stays sealed unless it boots *our* signed chain on *this* TPM, and then hits SDDM or the PIN)
- an offline-modified ESP, kernel, initramfs or cmdline (signatures plus the enrolled Limine hash)
- a fake root partition (PCR 15)

Not protected:
- a root-level compromise of the running system, which can sign with the local db key (same as upstream's plan)
- TPM bus sniffing on discrete TPMs (use `tpm2+pin`; systemd uses parameter encryption)
- rollback to an older *signed* UKI (a Phase 6 concern, handled by the signed PCR 11 policy)
- a user who is socially engineered into typing the recovery key into a malicious prompt

### 6.7 Docs to change

- `omarchy/manual/02-getting-started.md:7`: replace the paragraph with "Put Secure Boot in **Setup Mode**. Kitchen enrolls its own keys and turns Secure Boot back on. Leave the TPM alone; Kitchen uses it."
- `omarchy/manual/44-mac-support.md:19–28`: keep it. T2 Macs are a real exception (Apple's own Secure Boot, no user key enrollment), but say *why*.
- `README.md:79` and `manual/51-unattended-installs.md:47`: `pre-enrolled-keys=0` stays and becomes the *recommended* VM setting, now with the explanation "this gives you Setup Mode, and the installer enrolls keys".

---

## 7. Change #2: the Custom screen

### 7.1 Where it sits

```
keyboard → user → ┌ How should we cook? ────────────────────────────┐ → disk → [SB setup screen, §6.2, if needed]
                  │ > Omakase   our defaults, shown in one summary   │   → wipe summary (§4) → install
                  │   Custom    choose layout, swap, encryption      │   → recovery key (§6.5) → reboot
                  │   From file load install.toml from a USB drive   │
                  └──────────────────────────────────────────────────┘
```

**Omakase** shows the resolved defaults as a table (filesystem, swap, encryption and unlock, Secure Boot outcome) and lets you [Install] or [Customize…]. It never hides what the defaults are.

### 7.2 The screen

It is one gum form, with rows editable in place and help on the right.

```
  Custom install
  ─────────────────────────────────────────────────────────────────────────
  Filesystem       btrfs  ▸                  snapshots + factory reset need btrfs
  Separate /home   no     ▸                  no · partition on this disk · another disk · reuse existing
  Swap             zram + hibernation ▸      zram · zram + hibernation · partition · file · none
  Encryption       encrypted, TPM unlock ▸   see Disk encryption (§5)
  Disk passphrase  same as login ▸           same as login · separate
  Keep passphrase  yes ▸                     fallback when TPM refuses
  Secure Boot      enforce, own keys ▸       enforce · off
  Bootloader       Limine ▸                  Limine · systemd-boot (no snapshot boot)
  ESP size         2 GiB
  ─────────────────────────────────────────────────────────────────────────
  [Save as install.toml to USB]   [Continue]   [Back]
```

**"Save as install.toml to USB"** writes the TOML to any mounted vfat or ext4 stick (never the target disk). One interactive install thereby produces the config for every later rebuild.

### 7.3 What each choice changes downstream

| Choice | Configurator / plan | Orchestrator |
|---|---|---|
| **ext4 / xfs** | Layout emits a single root partition, no subvolumes | `finalize_limine_boot`: drop the snapper-config assert. Skip `snapper.sh`, `limine-snapper-sync`, `btrfs quota`, and `create_factory_snapshot` (it already skips non-btrfs). Cmdline has no `rootflags=subvol=@ rootfstype=btrfs`. Remove the snapshot-overlay hook from HOOKS. Hide "factory reset" in the Omarchy menu. |
| **/home: partition** | Two partitions on the target. With encryption, `/home` is a second LUKS2 volume. | `crypttab` (not `.initramfs`) unlocks `/home` with a keyfile in `/etc/cryptsetup-keys.d/home.key` on the encrypted root, so there is one prompt (or zero with TPM) at boot. |
| **/home: another disk** | That disk also gets a wipe summary, a *second* typed confirmation, and appears under "What dies". | Same as partition. Recommended for the "reinstall root, keep home" workflow. |
| **/home: reuse existing** | Pick a partition. The plan asserts its fs type and shows the used space. **Not formatted.** | Mount, `chown` the created user's home only if the UID differs (asks first). If it is LUKS, ask for its passphrase and add a keyfile slot. |
| **Swap: zram** | no swapfile | Skip `configure_hibernation`. No `resume` hook or param. |
| **Swap: partition** | Swap partition ≥ RAM (inside LUKS when encrypted, as its own LUKS2 volume with a keyfile) | `resume=UUID=…`, no `resume_offset` |
| **Swap: file on ext4/xfs** | n/a | `omarchy-hibernation-setup` gains a non-btrfs branch: `fallocate` + `filefrag` offset instead of `btrfs filesystem mkswapfile` / `map-swapfile`. Today the script is btrfs-only (lines 88–135). |
| **Swap: none** | n/a | Also remove the zram-generator drop-in |
| **systemd-boot** | Plan warns "no snapshot boot entries" | New `_configure_systemd_boot` beside `_configure_limine_boot`. Signing path is identical (sbctl signs `systemd-bootx64.efi` and UKIs). |

**Filesystem rule.** btrfs stays the default and the recommended choice, and the Custom screen says why in one line. Choosing ext4 is allowed. The plan lists what you lose, and nothing is silently degraded.

---

## 8. Phasing

| Phase | Contents | Exit criteria |
|---|---|---|
| **0** | #4 wipe summary + picker fixes (cidata exclusion, serials, `lsblk -J`, min-size check). #5 visible encryption choice (passphrase / none). Manual line 7 rewritten. | Two identical virtio disks in the test harness render distinguishably. Typed confirm is required for a disk with signatures. The cidata disk is never offered. |
| **1** | #3 schema v1, `kitchen validate/plan/install`, compiler shim to today's JSON, wizard writes TOML, `/etc/kitchen/install.toml` + lock file, cidata accepts TOML | Every existing `omarchy-iso-test` scenario passes when driven from TOML. `kitchen config export` round-trips. |
| **2** | #2 Custom screen. Orchestrator reads `InstallPlan` directly. ext4/xfs, `/home` variants and swap strategies land. | Test matrix below, rows A–H |
| **3** | systemd initramfs for all installs. Snapshot-overlay hook verified or ported. Provisioning keyfile moved to crypttab. | Snapshot boot works. Themed LUKS prompt works. Deferred provisioning re-key works. |
| **4** | Signed boot: Setup Mode detection, sbctl enrollment, Limine config enrollment, hooks, BootNext for Windows | Rows I–L |
| **5** | TPM2 unlock: first-boot enrollment, PCR 7+15, recovery key UX, autologin rule, `kitchen tpm reenroll` | Rows M–P |
| **6** (later) | Signed PCR 11 policy, `systemd-pcrlock` evaluation, optional shim+MOK path so the USB itself boots with SB on | n/a |

### 8.1 Test matrix

QEMU with OVMF (Setup-Mode vars) and `swtpm`, extending `bin/omarchy-iso-test`.

| Row | Scenario | Asserts |
|---|---|---|
| A | btrfs + zram+hibernate + passphrase (today's default) | Parity with upstream: boots, snapshots, factory snapshot, autologin on |
| B | ext4 + zram, unencrypted | Boots. No snapper. "You lose" lines were shown. SDDM login screen. |
| C | xfs + swap partition + passphrase | Resume from hibernate works |
| D | btrfs, `/home` on second virtio disk, encrypted | One prompt at boot. `/home` unlocked via keyfile. |
| E | `/home` reuse of D's disk after wiping only the root disk | Files survive. UID handled. |
| F | Unattended `on_existing_data = "abort"` against a disk with data | Install refuses. Table in the log. |
| G | Unattended with a stale `expect_fingerprint` | Install refuses |
| H | cidata drive present *and* invalid | The wizard never lists the cidata drive |
| I | OVMF in Setup Mode, SB auto | Enrolled. Boots with SB enforcing. `sbctl verify` clean. |
| J | Tamper: flip a byte in the UKI on the ESP | Firmware refuses to boot it |
| K | Tamper: edit `limine.conf` | Limine refuses (hash mismatch panic) |
| L | Kernel update + new snapper snapshot | New UKI and snapshot UKIs signed. Config re-enrolled. Reboots cleanly. |
| M | swtpm + SB enforced, unlock = tpm2 | First boot asks once. Second boot is silent, lands on SDDM login (no autologin). |
| N | Disable SB in OVMF after M | TPM refuses. Recovery key works. `kitchen tpm reenroll` restores silent unlock. |
| O | Fake-root swap: after unlock, try `systemd-cryptsetup` unseal again from userspace | Refused (PCR 15 extended) |
| P | unlock = tpm2+pin | PIN prompt via Plymouth. Autologin on. |

**Hardware validation** is the same idea as upstream's plan:
- one AMD desktop with a discrete GPU (proves the `--microsoft` option-ROM requirement)
- one Intel laptop with fTPM
- one Windows dual-boot laptop with BitLocker (BootNext path)
- one Framework

---

## 9. Open questions

1. **Snapshot overlay under a systemd initramfs.** Does `limine-snapper-sync` ship a systemd-compatible hook? If not, porting it is Phase 3's critical path.
2. **Microsoft 2023 CAs.** Microsoft's 2011 Secure Boot CAs expire during 2026. Confirm that the shipped sbctl's `--microsoft` bundle includes the 2023 UEFI CA and KEK, so newer option ROMs and Windows boot managers keep verifying.
3. **The exact Limine config-enrollment key.** Confirm the key name in `limine-entry-tool` (`/etc/default/limine`) for the shipped `limine-mkinitcpio-hook` version, and whether `limine-snapper-sync` re-runs enrollment itself.
4. **Firmware that won't enter Setup Mode.** Some locked OEM laptops have no Setup Mode. The options are the Phase 6 shim+MOK path, or install without signed boot (recorded, and reversible with `kitchen secureboot enable` once firmware allows it).
5. **Upstream relationship.** Phases 0–1 are small, self-contained and arguably upstreamable (wipe summary, cidata exclusion, TOML). Decide whether to offer them upstream before the fork diverges on initramfs and boot.
6. **Name.** Settle the CLI name before Phase 1 ships, because it appears in every user's `install.toml` workflow.

---

## Appendix A: Example configs

**Desktop, two NVMe drives, root on one, `/home` on the other, TPM unlock:**
```toml
schema = 1
[system]
hostname = "marvin"
timezone = "America/Toronto"
keyboard = "us"
[[users]]
name = "kevin"
password_hash = "$6$…"
[disk]
target = { serial = "S69ENX0T812345" }
mode = "wipe"
on_existing_data = "abort"
[disk.layout]
filesystem = "btrfs"
home = "disk"
home_disk = { serial = "S69ENX0T899999" }
[swap]
strategy = "zram+hibernate"
[encryption]
enabled = true
unlock = "tpm2"
recovery_key = { show = true }
[boot]
secure_boot = "require"
[desktop]
theme = "tokyo-night"
agent = "claude"
```

**Headless Proxmox VM, unattended, not encrypted:**
```toml
schema = 1
[system]
hostname = "kitchen-ci"
timezone = "UTC"
[[users]]
name = "ops"
password_hash = "$6$…"
ssh_authorized_keys = ["ssh-ed25519 AAAA…"]
[disk]
target = { path = "/dev/vda" }
mode = "wipe"
on_existing_data = "wipe"
[swap]
strategy = "zram"
[encryption]
enabled = false
[boot]
secure_boot = "auto"          # OVMF with pre-enrolled-keys=0 is Setup Mode, so it gets enforced anyway
```

## Appendix B: Sources

- Omarchy source: `basecamp/omarchy`, `omarchy-iso`. The file and line references above are from the 2026-09-25 HEAD.
- Upstream plan: `omarchy-iso/plans/consumer-secure-boot.md`
- Limine Secure Boot semantics (config checksum enrollment, EFI-chainload exception): https://github.com/limine-bootloader/limine/blob/trunk/USAGE.md
- Working Omarchy + sbctl + Limine reference: https://github.com/peregrinus879/omarchy-secureboot
- sbctl enroll-keys flags: https://man.archlinux.org/man/sbctl.8
- PCR meanings and recommendations: https://man.archlinux.org/man/systemd-cryptenroll.1
- systemd-pcrlock (experimental; Phase 6): https://man.archlinux.org/man/systemd-pcrlock.8
