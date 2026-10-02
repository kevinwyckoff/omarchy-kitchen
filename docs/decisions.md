# Decisions

Newest first. Each entry says what was decided, why, and what would change it. When a decision changes, add a new entry that supersedes the old one rather than editing history.

## 2026-10-02: kitchen-sink: the snapshot sync keeps the ESP under 65%, and snapshot 1 is gone

**Decision.**
- **`LIMIT_USAGE_PERCENT`** in kitchen-sink's `/etc/limine-snapper-sync.conf` is now 65, down from 85, with `MAX_SNAPSHOT_ENTRIES` left on `auto`. When a new snapshot would pass 65%, limine-snapper-sync drops the oldest snapshot boot entries and their UKI copies.
- **Snapper snapshot 1** (2026-09-26, the fresh install) is deleted, with Kevin's approval. Its boot entry used an unsigned UKI from before Secure Boot, so it could not boot anyway.

**Why.** Each update's pre-update snapshot keeps a copy of the UKI that was current then, about 271 MiB, in `limine_history`. 85% of the 2 GiB ESP leaves about 307 MiB free. But the updater holds any night that rebuilds the UKI unless the largest boot file plus `ESP_MARGIN_MIB` (about 335 MiB) is free, and the check-up warns below 700 MiB (`BOOT_WARN_MIB`). On 2026-10-02 the first unattended night (DONE, 20 packages) left 688 MiB, a WARN, with four UKI copies. At 65%, at most three copies fit, which leaves about 950 MiB free and never less than about 716 MiB.

**Findings.**
- **Deleting snapshot 1:** limine-snapper-sync removed its entries and UKI copy, rewrote `limine.conf`, enrolled the new config hash and re-signed Limine. Omarchy's two re-seal watchers finished cleanly. `kitchen-update --boot-check` passed: Secure Boot clean, every active boot file signed, 959 MiB free. `limine-snapper-info` showed 53% of 2 GiB (max 65%), 4 entries, 3 files and nothing missing or corrupted.
- **The FireCuda's error log** went up by 3 across 2026-10-01's power-off and cold boot. `nvme-cli`, now installed, reads the log, and the drive keeps only its last two entries (459 and 460). Both are Invalid Command Opcode on the admin queue: something sent the drive an admin command it doesn't support, and it logged the refusal. Its 460 lifetime entries are of that kind, with 0 media errors and 100% spare. Neither the probe nor arming the drive moved the counter when re-run. The WDC has one old entry, not tied to any command.

**What would change it.** A larger ESP, or a much smaller UKI. Snapshots that share a UKI already share one copy, since the files are named by hash.

## Findings, 2026-10-01: the system NVMe's temperature AEN on real hardware (kitchen-sink)

This closes the 2026-09-29 entry's open FireCuda item.

- **The probe** on this boot found the same as 2026-09-29: the FireCuda 520 is case A, with OAES and feature 0Bh both 0x200, and the WDC is case B. The two drives swapped names at this boot (the FireCuda is now `nvme0`). The daemon goes by serial, so nothing changed.
- **Armed.** The machine's `/etc/kitchen-sink/thermal.conf` now says `NVME_ARM="system"`. After `systemctl reload kitchen-thermal`:
  - the daemon logged "AEN configuration 0x200 -> 0x202";
  - the NVMe source is in event mode;
  - the drive is at level normal, at 35 °C, with an over threshold of 70 °C and no under threshold.
- **The threshold test.** One threshold was written across the current temperature through the nvme hwmon, the same Set Features 04h the daemon uses. Each write made the drive send its own temperature AEN, and the kernel passed it on as `NVME_AEN=0x020101`:

  | Written | AENs | The daemon put its threshold back |
  | --- | --- | --- |
  | `temp1_max` 30 °C, with the drive at 33 °C | 2 | 0.31 s later (70 °C) |
  | `temp1_min` 37 °C, with the drive at 34 °C | 3 | 2.02 s later (off) |

  The level never left normal, so there was no `nvme-hot` event, toast or journal line, only the rewritten thresholds. Afterwards `temp1_alarm` was 0.
- **Not done:** a real `nvme-hot` from heat (it needs the drive at 70 °C), and seeing the arming come back after a reboot. The controller start clears feature 0Bh, and the daemon is meant to set it again.

## 2026-10-01: kitchen-sink: the GPU check pauses owe's video wallpaper while it measures

**Decision.** `safe-to-update`'s GPU check pauses owe, Omarchy's wallpaper engine, for its 5 s measurement and resumes it after. A video wallpaper is not someone using the machine. Kevin chose this over a still wallpaper or a higher `GPU_MAX`. A higher limit would have left the "decoder active" check blocking, and would have hidden a video someone is watching.

**Findings on kitchen-sink.**
- **The first unattended night was DEFERRED.** All four slots were BUSY with "gpu: busy 16-17% (limit 15%)" and "video encoder or decoder active". The only process on the decoder was `owe-render`, which plays the theme's video wallpaper through mpv (hwdec vaapi).
- **It plays all night.** Omarchy's Stay Awake is on, so the screen never sleeps, and owe's `occupied_workspace` pause only applies while a window covers the desktop.
- **Per-process accounting can't subtract it.** On this GTX 1650, `nvidia-smi pmon` gives no figures for graphics work: Hyprland showed "-" while the GPU was 10% busy.
- **Pausing it isolates it.** With today's `day.mp4` wallpaper, the GPU was 10% busy playing, 4% paused (Hyprland alone) and 10% again after `owe resume`. `owe resume` clears only the manual pause, so owe's own policy takes over again.
- **What the check leaves alone:** a pause owe already has, whether set by hand or by its policy, and a still wallpaper. A check killed during the measurement still resumes owe, through a trap held only for those seconds.

**Status.** Installed on kitchen-sink. Tonight is the first night with it.

**What would change it.** owe pausing itself on an idle session, or Stay Awake being turned off so the screen sleeps.

## 2026-10-01: kitchen-sink: kitchen-thermal makes the NVIDIA device nodes before it starts

**Decision.** `kitchen-thermal.service` runs `ExecStartPre=-+/usr/bin/nvidia-modprobe -c255 -c0`. This takes up the 2026-09-30 candidate for NVML starting degraded after a boot. A shorter first retry would only have shortened the gap; this removes the cause.

**Findings on kitchen-sink.**
- **Nothing makes `/dev/nvidiactl` and `/dev/nvidia0` at boot.** nvidia-utils' udev rule runs `nvidia-modprobe -c0 -u`, and with `-u`, `-c` means the UVM minors: `/dev/nvidia-uvm` and `nvidia-uvm-tools` were made at 15:51:24.07. The first NVIDIA client makes the other two through the setuid `nvidia-modprobe`. On 2026-09-30 that was the desktop session, at 15:51:26.396.
- **The daemon cannot be that client.** Its sandbox has `NoNewPrivileges`, `RestrictSUIDSGID` and no `CAP_MKNOD`. Its `nvmlInit` ran at 15:51:26.004 and got "Driver Not Loaded", and the next try came 600 s later. Without a desktop session, GPU events would have stayed off until some other NVIDIA program ran.
- **Reproduced without a reboot,** in a private mount namespace with an empty `/dev` (plus `/dev/char`, as udev provides), running NVML under the unit's restrictions (`setpriv --no-new-privs`, bounding set `CAP_SYS_ADMIN`):

  | Made first | NVML |
  | --- | --- |
  | nothing | `nvmlInit` 9, Driver Not Loaded, as at boot |
  | `-c0` (`nvidia0`) | `nvmlInit` 9 |
  | `-c255` (`nvidiactl`) | `nvmlInit` works, but there is no device handle |
  | `-c255 -c0` | `nvmlInit`, the handle, the event set and registering for events all work |

- Without `/dev/char`, `nvidia-modprobe` exits 1 after its first node, because it also makes the `/dev/char/195:N` links. udev makes `/dev/char` long before this unit starts.
- `+` runs only NVIDIA's own helper outside the sandbox; the daemon gains nothing. `-` keeps a machine without the helper starting, with NVML degraded as before. In the test containers, `systemd-analyze verify` stays clean, and the unit starts without the helper.

**Status.** Installed on kitchen-sink, and proven at the next boot (2026-10-01 13:43). The unit made both nodes 7 ms after it started, NVML was in event mode 150 ms later, and the desktop session opened a second after that.

**What would change it.** nvidia-utils making the nodes at boot itself, or NVIDIA moving the nodes to devtmpfs.

## 2026-09-30: kitchen-sink: the nightly updater is on

**Decision.** `kitchen-update.timer` is enabled on kitchen-sink. Every step in the README's "Turning on the nightly updater" passed on the machine, so the first unattended night is 2026-10-01. This supersedes the 2026-09-28 entry's "its timer stays off until one supervised run at the machine".

**Findings on kitchen-sink.**
- **Dry run** (over SSH, `--quiet-secs 60`):
  - Every static gate was ok.
  - The preflight said GO-WITH-CARE, for the boot chain: glibc, limine, mkinitcpio, limine-mkinitcpio-hook and plymouth.
  - The verdict was DEFERRED, as documented for a run after 05:30.
  - Besides its own SSH session, the activity check caught real use: typing on a terminal 13 minutes earlier and an agent transcript written 14 minutes earlier.
- **Negative dry runs,** combined into one run, since each check prints its own line. A second SSH session, `systemd-inhibit --what=idle --mode=block` and a key Kevin pressed 29 s into the input window each turned their check BUSY.
- **Grant test:** passed.
  - With the group, `sudo -n` worked, for a grandchild too; without it, `sudo -n` was refused.
  - `newgrp kitchen-update` was refused.
  - The rule was removed afterwards, and `sudo -l` was the same as before.
- **The supervised run.** It was started over SSH from Marvin with `force-idle`, and ended DONE.
  - 38 repo packages; the service took 54 s. The pin held omarchy-dev and omarchy-settings-dev back.
  - The shutdown inhibitor was held for the run.
  - **The AUR guard fired on real hardware.** The grant was removed as Omarchy's "Update AUR packages" phase started, and the revoke step found it already gone. There was nothing to build: the only foreign package, `nct6775-notify-dkms`, isn't in the AUR.
  - **limine-mkinitcpio-hook 1.40 kept the log lines the postflight matches.** The postflight passed with no false DO NOT REBOOT, and `lib/postflight` needed no change.
  - The postflight also found the UKI built for the running kernel and signed, the NVIDIA and patched nct6775 modules built for it, Secure Boot clean, and no newly failed units. It recommended a reboot, because the UKI was rebuilt and Limine re-signed.
  - The toast was sent, according to the journal; nobody watched the screen for it.
  - **The ESP went from 1230 to 959 MiB free.** limine-snapper-sync copied the old UKI (about 270 MiB) into `limine_history` for the pre-update snapshot, and three UKIs are there now. The postflight's "room for the next UKI" check is what would catch the ESP filling.
  - `sbctl verify` still flags only the raw fallback loader and the one history UKI from before Secure Boot. The checks skip both by design (see 2026-09-27).
- **The reboot,** with the LUKS passphrase typed at the machine:
  - It was back in about 40 s, from the signed Limine entry, with Secure Boot enforcing. `kitchen-update --boot-check` passed.
  - **The patched nct6775 loads at boot through modules-load.d,** with `notify_interval=1000`, and the thermal daemon came up in event mode on it. That closes the 2026-09-29 entry's open reboot item.
  - **NVML starts degraded after a boot.** The daemon started at 15:51:25, two seconds after the nvidia module loaded, and `nvmlInit` returned "Driver Not Loaded". Its 600 s retry restored GPU events at 16:01:26, so each boot has a 10-minute gap. A check-up in that window would warn. **Candidate:** a shorter first retry, or ordering `kitchen-thermal.service` after the NVIDIA driver is ready.
- **Harness:**
  - Starting the real run from Marvin was first refused by the tool's safety check. Kevin then allowed the SSH helper's sudo form in the tool's settings, and the run, the reboot and enabling the timer went through it.
  - `omarchy secureboot status` under `sudo sh -c` fails, because `OMARCHY_PATH` is unset there. `kitchen-update --boot-check` runs the same check properly.
- **Cosmetic, not fixed:**
  - The DONE toast says "updated overnight", even for a daytime run.
  - The dry run's closing summary repeats each BUSY line from both passes when only its "N min ago" differs.

**Status.** The timer is on, with its first slot at 02:30 on 2026-10-01. The 09:00 check-up reports on each night.

**What would change it.** A night that FAILs or is held on the boot checks, or a limine-mkinitcpio-hook that rewords the lines the postflight matches.

## 2026-09-29: kitchen-sink: thermal and fan events come from a patched nct6775, the drives' own AENs and NVML

**Decision.**
- **Events, not a polling program.** Kevin wanted temperature and fan-ramp events even if the driver had to be rebuilt. The stock nct6775 has no notification at all, so kitchen-sink gets a patched one as a DKMS package, `nct6775-notify-dkms`, built from the Linux 7.2.5 source (`machines/kitchen-sink/pkg/`).
  - A sampler inside the kernel reads the chip every `notify_interval` (1 s). It wakes `poll()` readers when a pwm, fan or temperature moves past a delta, and sends a uevent (`hwmon_notify_event`) when an alarm sets or clears.
  - Off in the code (`notify_interval=0`); the package's modprobe.d file turns it on.
  - A second patch adds a read-only register dump in debugfs, off by default, that never reads the chip's read-to-clear registers.
- **One daemon, `kitchen-thermal.service`,** turns the Super I/O events, the NVMe drives' own temperature AENs, NVML's GPU events and the kernel log into journal lines, Omarchy hooks (`~/.config/omarchy/hooks/thermal.d`) and, for the few that matter, toasts. The check-up reports its state.
- **NVMe: only a drive listed in `NVME_ARM`,** and only a case A drive, where the stock kernel keeps an Asynchronous Event Request outstanding. The FireCuda system drive is case A. The WDC data drive is case B: it can send events only after an nvme-core rebuild, which is deferred.
- **No hardware interrupt.** The register dump shows none to use; see the findings below.
- **Smaller calls made during the deploy.**
  - A `--test-event` goes to the journal at notice at most, so a deploy check doesn't turn the next check-up to WARN.
  - install.sh offers each shipped config version once, like pacman's `.pacnew`: once the `.new` is merged and deleted, later runs keep the file quietly.

**Findings on kitchen-sink.**
- **Register dump (read-only).**
  - Logical device 0B CR70 is 0x00, so no IRQ is assigned. CR24 bit 2 is set, so the shared pin is SMI#, owned by the firmware.
  - OVT2, the CPU slot (SMBUSMASTER 0, limit 80 °C, hysteresis 75 °C), is disabled by DIS_OVT2, and OVT3-8 by bank C 0x06. OVT1 is on, but it watches AUXTIN0 at 127 °C.
  - The SMI mask (0x46 = 0x3f) masks the shutdown sources. So CPU heat can raise neither SMI# nor OVT#.
- **Load test.** 16 threads for 120 s took Tctl from 37 to 85 °C.
  - `poll()` woke on pwm2 24 times (it went to 255), pwm4 37 times and temp13 (TSI0) 22 times.
  - `temp7_alarm` sent exactly two uevents, set at 80 °C and cleared at 75 °C.
  - The fans settled back to idle afterwards.
- **Cost.**
  - The kernel: 0.95 ms a second, almost all of it about 39 LPC register reads at 24 µs, so about 0.1 % of one core.
  - The daemon: 81 ms of CPU a minute (0.14 % of one core) and 39 MB.
- **Delivery.** A test event sent through the running service ran the user's hook as the user.

**Status.**
- Live on kitchen-sink:
  - the package is installed, with the UKI re-signed and Secure Boot clean
  - the daemon is running, with the Super I/O, NVML, uevents and the kernel log all in event mode
  - the check-up is OK
- Not done:
  - **The FireCuda.** Arming it and the brief threshold test (drop its over- and under-temperature thresholds across the current temperature once each, watch for the AEN, let the daemon restore them) were refused from Marvin by the tool's safety check, although Kevin had approved them. So no drive is armed, and no NVMe AEN has been seen on real hardware yet.
  - **A reboot at the machine,** to see the module load through modules-load.d.

**What would change it.** Upstream nct6775 gaining change notification, a BIOS that routes the Super I/O interrupt, or the nvme-core rebuild for the WDC.

## 2026-09-28: kitchen-sink: the kitchen build is pinned, and it gets a daily check-up and a gated nightly update

**Decision.**
- **Pin the kitchen build.** Edge's omarchy-dev now sorts newer than the kitchen build (r6663 against r6647), and it has no Secure Boot engine. Installing it with Secure Boot on would leave Limine unsigned (limine 12.9.1 is pending), so the machine wouldn't boot.
  - kitchen-sink's `/etc/pacman.conf` has `IgnorePkg = omarchy-dev omarchy-settings-dev`.
  - A `pre-refresh-pacman` Omarchy hook restores the pin after `omarchy-refresh-pacman`.
  - Newer Omarchy reaches the machine only as a kitchen build installed by hand.
- **The daily check-up** (`machines/kitchen-sink/`) runs read-only at 09:00. It covers Secure Boot, the boot chain, the pin, failed units, disk space, NVMe health, btrfs and its scrubs, time sync, pending updates, reboots and leftover grants. It writes a report plus a toast (low, normal or critical), and nothing leaves the machine. Monthly btrfs scrubs of `/` and `/mnt/data` are on.
- **The nightly updater runs Omarchy's own `omarchy update -y`, only when the night's gates pass.** It tries at 02:30, 03:30, 04:30 and 05:30.
  - **Idle:** 10 minutes without input, and no SSH session, audio, fullscreen app, GPU or CPU load, or download.
  - **Compatibility:** a dry-run upgrade resolves, no Arch news since the last update, no AUR updates, room on the ESP, Secure Boot clean.
  - **Afterwards:** every UKI is signed and matches its kernel, the NVIDIA module is built, and Secure Boot is clean.
  - It never reboots, and it holds every later night while the boot chain needs attention.
- **sudo** comes from a per-run grant for an empty group, `%kitchen-update NOTAFTER=+120min NOPASSWD: ALL`. setpriv adds that group only to the update's process tree.
  - Stray carriers are killed, and the grant is dropped before the AUR phase.
  - It's revoked after the run, with ExecStopPost and boot-time removal as backstops.
  - The trade-off: Omarchy's hooks and mise run with root and nobody watching, which is the same trust an attended update gives them.
- **Machine details stay off this public repo.** The drive serials live only in the machine's own `/etc/kitchen-sink/checkup.conf`; the tree uses placeholders.

**Status.** The check-up and scrubs are live on kitchen-sink. The updater is installed, and its dry run and grant self-test passed on the machine. Its timer stays off until one supervised run at the machine.

**What would change it.** A kitchen build that tracks edge automatically, or upstream shipping the Secure Boot engine.

## Findings, 2026-09-27: Secure Boot on real hardware (kitchen-sink)

The machine is kitchen-sink:
- an ASRock B650M-HDV/M.2 with AMI BIOS 1.28 (UEFI 2.80, AMI 5.26)
- a Ryzen 7 7700X, whose Radeon iGPU was unused
- a GTX 1650 as the display
- omarchy-dev r6638, whose Secure Boot engine is byte-identical to kitchen's

`omarchy secureboot enable` was driven over SSH (pexpect over `ssh -tt`, answering sudo and the gum prompts), and the firmware steps were done at the machine.

- **Baseline.** An earlier session had left the firmware in Setup Mode with no keys, so Kevin installed the factory defaults:
  - PK is ASRock's (expired 2022)
  - KEK is Microsoft's KEK CA 2011
  - db holds Microsoft's UEFI CA 2011 and the Windows Production PCA 2011
  - dbx is the factory list (10160 bytes)
  - none of Microsoft's 2023 certificates are there
  
  CSM was off. Limine was moved to Boot #1, because the raw fallback ("UEFI OS") had been first.
- **Run 1** sealed and signed the boot files and backed up the factory keys. The missing 2023 KEK warning was accepted. With Omarchy's old `99-omarchy-limine.hook` still on this machine, a `limine` reinstall put the raw loader back, and the watcher re-sealed and re-signed it within 20 s. That's the watcher's repair on real hardware, and it's why the ISO no longer writes that hook.
- **The firmware step went down the rebuild path, not append.** The option used was a clear-all rather than the per-key "delete PK". It emptied KEK, db and dbx along with the PK, which the release checklist treats as a STOP for the append row. Kevin chose to go on with the rebuild path (Stage 7):
  - `enable` wrote db and KEK (Microsoft 2011 and 2023, the firmware's defaults, and ours) and PK, and read each back.
  - Nothing from the backup was lost except dbx.
  - After the reset, SetupMode was 0 (this firmware updates it only at a reset).
  - The next run confirmed, and Secure Boot was turned on in Custom mode.
- **Secure Boot enforcing:**
  - `bootctl` reports "enabled (user)", and the kernel logs "Secure boot enabled".
  - **The GTX 1650's option ROM runs.** The firmware chose it as the boot display (`boot_vga=1`, vgaarb "setting as boot VGA device"), trusted through Microsoft's UEFI CA in db.
  - The NVIDIA DKMS driver loads, because linux-omarchy doesn't enforce module signatures.
  - Across two restarts the sealed Limine and signed UKI boot, and `status` passes.
- **Updates with Secure Boot on:**
  - A kernel reinstall re-signs the UKI.
  - DKMS prints "Error! Installation aborted." on a same-version reinstall ("already installed at version …"). That's harmless, and a real kernel update builds fresh modules.
  - A `limine` reinstall is re-sealed by the watcher.
  - The new snapshots get entries.
  - `status` passes after each, and the guarded restart boots enforcing.
- **dbx.** The clear-all emptied dbx, and the engine never writes it. fwupd 2.1.8 offers no dbx release for an empty dbx (its version reads as null). dbx was put back from run 1's backup with efitools, signed with our KEK, and the live variable's hash equals the backup's. **Candidate:** the engine holds both the backup and the KEK, so it could offer this restore itself when a key menu wipes dbx.
- **Not done:**
  - the append path on this firmware (it needs the per-key PK delete; the menu's wording was not recorded)
  - refusal of the pre-enable snapshot entry (not observed)
  - the restore and remove drills (Stages 4 and 6)
  - the Windows rows (no Windows on this machine)
  
  The machine stays on Secure Boot with our keys.
- **Noise seen:**
  - Hyprland segfaults in `libaquamarine` at shutdown on this dual-GPU machine.
  - The firmware logs ACPI `AE_ALREADY_EXISTS` errors.
  - The three NvPCR units fail, as before.
- **Harness:** `systemctl reboot --firmware-setup` over SSH needs sudo, because polkit wants interactive authentication.

## 2026-09-27: Keyboard, console font, minimums and install-log fixes

**Decision.** Everything below went through review and QEMU before landing. Each is its own topic branch from `quattro`, or a commit on the chain branch that introduced the bug.
- **The login greeter uses the installed keyboard layout** (omarchy `greeter-keyboard-layout`). SDDM's Hyprland always used US, so a non-US user typed their password on the wrong layout at the greeter. The greeter now reads `/etc/vconsole.conf` through a shared `default/hypr/keyboard.lua`, and falls back to US if that fails. **Behaviour change:** it follows the system layout, not a user's `input.lua` override, because SDDM can't know who will log in.
- **Nine picker layouts now reach Hyprland** (`picker-layouts-reach-hyprland`, in both omarchy and omarchy-iso). systemd's kbd-model-map has no row for colemak, azerty, bg-cp1251, cz, de_CH-latin1, kyrgyz, no-latin1, pl or ua. Those users got their console keymap but a US desktop.
  - The picker list now carries an XKB layout for each of them, and both writers add it: the ISO's `keyboard.py` and first-boot provisioning.
  - "Azerbaijani|azerty" becomes "French (AZERTY)", because kbd's azerty is French and kbd has no Azerbaijani keymap.
  - **The LUKS prompt stays on the console keymap.** With XKBLAYOUT set, Plymouth switches from the console keymap to XKB, and for azerty and no-latin1 some keys type different characters: `$` is Shift+4 on the no-latin1 console but AltGr+4 in XKB `no`. So when `vconsole.conf` carries exactly the picker's pin, a new `omarchy-vconsole` initcpio hook puts the file into the initramfs without the XKB lines. Any other file goes in through `FILES+=` as before.
  - Upstream omarchy #11418, #8685 and #11056 each cover part of this; none fixes both writers.
- **First-boot provisioning keeps the console font** (`first-boot-keeps-console-font`). `systemd-firstboot --force` drops `FONT=`, so deferred and factory-reset machines lost `default8x16` and the consolefont hook, with a warning on every UKI rebuild. They now match direct installs, as upstream omarchy-iso #93 intends.
- **chefs-kitchen:** `validate` checks only that `keyboard` is shaped like a keymap name, so it gives the same answer on any host. `plan` checks the keymap exists and refuses before anything is erased. `validate` also takes `--config`, like `plan` and `install`.
- **Minimums:**
  - Full-disk is 32 GiB total. Our 34 GiB rested on a misreading of the free-space minimum, which counts the 2 GiB ESP inside the 32; upstream has no full-disk minimum.
  - An exact 32 GiB free-space gap now fits. parted reports a free region's end byte inclusively, which lost a MiB.
  - The free-space ESP is exactly 2 GiB. It was one sector over, leaving a 1 MiB hole and a 30719 MiB root.
  - The last two are upstream bugs too, fixed on `free-space-tip`.
- **Log and screen wording:**
  - `honest-progress-lines`: no "+ encrypting" on plain installs, and no "creating user" line for deferred provisioning.
  - The swap-strategy line says what each strategy leaves.
  - The free-space wipe summary no longer numbers the partitions it will create.
  - A blank disk is offered for use rather than erasure.
- **No fix:**
  - The "Unable to resume from device" line: Plymouth captures it on a normal boot.
  - The one-off `setfont` ENOSYS: it's a race in mkinitcpio's consolefont hook. The hook-reorder idea is kept on the local branch `inv-vconsole/console-hooks-before-plymouth` for a try on real hardware.
  - archinstall's empty-keymap log lines: that's upstream's deliberate skip path, and the end state is right.

**What would change it.** Upstream taking any of these a different way; systemd adding kbd-model-map rows for the pinned keymaps; or upstream #13362 landing, since it restructures the hooks files.

## Findings, 2026-09-27: these fixes in QEMU

The ISO was omarchy-dev r6647, and each scenario's audit re-checked its evidence.
- **German, whole 32 GiB disk, unencrypted, `swap = "none"`:**
  - accepted and installed
  - the log lines are right
  - the greeter's Hyprland uses `de`; a password typed on German key positions logs in, and the same keys at US positions are refused
- **Norwegian (no-latin1), encrypted, passphrase with `$`, graphical Plymouth prompt with no serial port:**
  - Shift+4 unlocks and AltGr+4 is refused.
  - An extra keyslot with `+` proved the prompt reads the no-latin1 console keymap, not a US fallback.
  - The initramfs `vconsole.conf` has no XKB lines, and the package files are unmodified.
  - A control boot without the hook failed on Shift+4.
- **`keyboard = "german"`:** `validate` passes, `plan` refuses, and the unattended install stops before touching the disk. The disk was byte-identical afterwards.
- **Free space with Polish:**
  - A gap 1 MiB short of 32 GiB is refused, and an exact 32 GiB gap is accepted.
  - The ESP is exactly 4194304 sectors, root starts on the next sector and is 30720 MiB, and the Windows partitions are unchanged.
  - Polish reaches the greeter and the session.
- **Deferred provisioning, owner picks Polish:** no "creating user" line, `FONT=default8x16` kept, no consolefont warning, and the owner's passphrase unlocks.
- **Harness lesson.** A `-serial` port makes systemd-stub add `console=ttyS0`. Plymouth then drops to its text prompt, which reads keys through the console keymap whatever the initramfs says. LUKS-keyboard rows must boot with `-serial none`. This is now in `scripts/qemu/README.md`.
- **Suites:** omarchy 269 shell tests and omarchy-iso 186 Python tests plus all shell tests showed no regressions against the old kitchen, and every new test fails on the old code.
- **Candidates noticed, not fixed:**
  - A free-space install's log doesn't record which partitions chefs-kitchen created.
  - Hibernation's `resume=` uses a kernel device name (`/dev/vda5`) on unencrypted multi-disk machines, and NVMe numbering changes between boots on kitchen-sink.
  - After a free-space install, the Limine menu has no Windows entry: `FIND_BOOTLOADERS` scans only Omarchy's own ESP.
  - `validate` still checks timezones against the host's tzdata.
  - The picker's "Lao|la-latin1" row is really Latin American Spanish (upstream #11004/#11056).
  - Machines already installed with one of the nine keymaps get no migration; picking the layout again fixes them.
  - German and French passphrases with non-ASCII letters differ between the console keymap and Plymouth's XKB (upstream #8680/#8682).

## 2026-09-26: The encrypt hook: carry omarchy#9686, not omarchy-iso#143

**Decision.** This supersedes the "carry #143" candidate in the entry below.
- **Carry omacom/omarchy#9686** (open, no reviews) at the bottom of the omarchy `kitchen` stack, above #11388, the same way as #11388: an upstream PR, carried until upstream merges it, never a PR of ours. A local `pr-9686` branch holds it.
  - It adds a filter to the packaged `omarchy_hooks.conf` that drops `encrypt` only when the root is verifiably plain: ext4 or btrfs on a `/dev/*` whose `lsblk` stack is only disk and partition, no `cryptdevice=`, `cryptkey=` or `crypto=` on the command line, and no active `crypttab.initramfs`. It keeps the hook whenever it can't tell.
  - Migration 1788279117 rebuilds existing plain-root installs once.
- **Why not #143.** It edits a file that `omarchy-settings` owns and lists in `backup=()`, so on every install it touches:
  - the file freezes, and each later upstream change to it becomes a `.pacnew` that nothing applies
  - `omarchy-channel-set` silently puts `encrypt` back
  - its pattern also matches the indented NVIDIA line, so encrypted installs get that line rewritten, and NVIDIA-only machines run `encrypt` twice
  - our own fix for that turned into a hard install failure once omarchy#13362 (open) moves the hook list out of the file
  - an ISO-side fix belongs in an installer-owned drop-in, never in the package's own file

**What would change it.** Upstream merging #9686, or #13362 landing first. #9686 then needs a rebase, which should be trivial because it's a filter.

## Findings, 2026-09-26: #9686 in QEMU

Built from an ISO with omarchy-dev r6643. Each scenario's audit re-checked it independently.
- **Unencrypted install:**
  - The boot image built in the installer's arch-chroot has no `encrypt`. There, `/proc/cmdline` is the live ISO's, and `findmnt /` sees `/dev/vda2` with an `lsblk` stack of partition and disk.
  - No "Failed to open encryption mapping" on first boot or after a rebuild. A positive control (forcing the hook back) shows that error on the serial console at exactly the point where these boots are clean.
  - `omarchy_hooks.conf` stays unmodified (`pacman -Qkk`), and there are 0 failed units.
- **Encrypted install:**
  - In the installer chroot the stack is `crypt part disk`, so `encrypt` stays (exactly once, before `filesystems`). The command line alone would have dropped it; the `lsblk` check is what keeps it.
  - The passphrase prompt unlocks on both boots.
  - Run by hand, the migration exits without rebuilding.
- **Encrypted deferred provisioning:** the first boot unlocks through `cryptkey=` with no prompt. After the owner is provisioned and the disk re-keyed, `encrypt` is still there, and the next boot prompts for the owner's passphrase.
- **Existing unencrypted install** (made from the morning ISO, r6638):
  - Before the fix it shows the error.
  - `pacman -U` of the new packages replaces the unmodified hooks file, with no `.pacnew`.
  - `omarchy-migrate` runs only 1788279117, which rebuilds without `encrypt` and doesn't repeat. The next boot is clean.
  - Not exercised: the real `omarchy update` path. There, the no-update sudo wrapper revokes the timestamp before migrations, so the migration's `sudo limine-mkinitcpio` would ask for the password again. Encrypted machines such as kitchen-sink exit before any sudo call.
- **Seen along the way, unrelated to #9686:**
  - Every boot on an install with hibernation prints "Unable to resume from device … continuing boot process." The resume hook prints it whenever there's no hibernation image, and it looks like an error.
  - The installer prints "› partitioning + formatting + encrypting" even when not encrypting (`phases_impl.py`, upstream code). Candidate: a one-line fix on `visible-encryption`.
  - A consolefont warning ("no font found") after provisioning's keyboard step, and a one-off `setfont` error on one encrypted first boot. With the empty vconsole keymap seen earlier, that points to the keyboard/vconsole path. Candidate: look into it.

## 2026-09-26: Fixes from the first real-hardware installs

**Decision.**
- **"Done" waits for the laptop.** The Windows+BitLocker row (BootNext, `omarchy secureboot windows setup|bootnext`) and the laptop-hint check wait until Kevin has procured a laptop. The row stays a Phase 2 exit criterion, so the upstream PRs stay held until it passes.
- **Missing sync databases: carry upstream's fix.** omacom/omarchy#11388 (open) syncs any repository that has never been synced, in `post-install/pacman.sh` and in `omarchy-pkg-add` and `omarchy-pkg-aur-add`, through a new `omarchy-pkg-db-sync`. It sits at the bottom of the omarchy `kitchen` stack, unchanged except for keeping quattro's `--` in `omarchy-pkg-aur-add`, and a local `pr-11388` branch holds it. It gets no PR of ours. It also fixes Phase 2: `omarchy secureboot enable` begins with `omarchy-pkg-add sbctl efibootmgr`, and sbctl isn't installed. It's in the offline mirror, but the mirror is gone after install. The Phase 2 shape entry's "so `enable` works from the offline mirror" was wrong: without the fix, `enable` failed on a fresh install until a full update ran.
- **`99-omarchy-limine.hook` goes on standard UEFI installs** (omarchy-iso `drop-limine-copy-hook`). The packaged `80-limine-efi-deploy.hook` already runs `limine-install`, which deploys the same loader to the same path, keeps the `.bak` and leaves sealing and signing intact. The hook stays for BIOS, for the removable `EFI/BOOT` slot and for any other loader path. No omarchy migration for existing installs yet: kitchen-sink keeps its hook so the hardware row can show the watcher re-sealing after it. omacom/omarchy#12246 removes the hook by migration but then runs `sbctl sign -s` on the loader, which needs checking against sealing before we rely on it.
- **ufw in the install chroot** (omarchy-iso `quiet-ufw-chroot`). The "ERROR: problem running" message was hiding a bug. `firewall.sh` sets ENABLED=yes first, so a later `ufw allow` tries to load rules into the live ISO's netfilter and dies after writing the IPv4 rule, before the IPv6 one. Every install with SSH access had port 22, and tailscale0, open over IPv4 only. The installer now runs `ufw allow` with ENABLED=no and restores the file afterwards. Both families get written, and a non-zero exit fails the phase. **This changes behaviour:** SSH is now reachable over IPv6 too, which is what `ufw allow ssh` asks for.
- **The live greeter waits for an address** (private `live-ssh`). With live SSH on, it waits for an IPv4 address before drawing the SSH hint, showing "waiting for a network...". It checks up to 20 times, half a second apart (about 10 s). Return ends the wait, and it's skipped inside an SSH session.
- **NvPCR failures on AMD fTPMs are a known issue, not a fix.** Omarchy masks nothing. Acceptance runs on such hardware pass `OMARCHY_ACCEPTANCE_IGNORE_UNITS='systemd-(tpm2-setup-early|pcrproduct|pcrlogin@)'`. Revisit before TPM2 unlock.
- **omarchy synced to upstream c5b4db77.** That takes in #13323, one sudo prompt per `omarchy update` where we answered about nine, and #13361, which removes the `setpriv` TERM message at the end of an update. Both were findings of ours.

**What would change it.** Upstream merging or rejecting #11388 or #12246, or a laptop arriving.

## Findings, 2026-09-26: the fixes in QEMU

Four scenarios, run in parallel from one ISO built from `build/live-ssh` with local omarchy `kitchen` (omarchy-dev r6642). The baseline was an A/B against the morning ISO (dae8932).

- **Morning ISO, unattended online install:** it has the 99 hook. `ufw status` shows 22 for IPv4 only, and `user6.rules` and `ip6tables` have no port 22. "ERROR: problem running" appears only in the live `/var/log/omarchy-install.log`. There are no core, extra, multilib or omarchy databases, and `omarchy-pkg-add sbctl` fails with "target not found".
- **New ISO, the same install:**
  - no 99 hook
  - a `limine` reinstall after the loader was made stale redeploys it through the 80 hook; one Limine NVRAM entry remains, and the machine boots through it
  - 22 and 22 (v6) allowed, with ENABLED=yes restored
  - no ufw error
  - the databases are synced during the install, and `omarchy-pkg-add sbctl efibootmgr` works
  - 0 failed units
- **New ISO, installed with the link down throughout:**
  - The install finishes, with all 16 phases ok.
  - The install-time `pacman -Sy` fails with DNS errors in the log without failing the phase.
  - After the link comes up, the first `omarchy-pkg-add` runs one `pacman -Sy` and installs. A second `omarchy-pkg-db-sync` does nothing.
- **Greeter:**
  - Link down: "waiting for a network...". The link came up about 4 s later, and the address showed 0.5 s after that; SSH works.
  - Link never up: the old fallback line, then Return works.
  - Return during the wait: the next step appears in 0.23 s.
  - No keys: no SSH line and no delay.
  - The wait counts checks, not seconds, so under host load it stretched to 12–15 s.
- **New, not caused by these fixes:**
  - **The target's install log stops at "User finalization complete."** The later phases write only to the live log, and an unattended install reboots and loses it. That's why kitchen-sink's disk never showed the ufw error. Candidate: copy the live log to the target once the last phase is done.
  - **Unencrypted installs print "Failed to open encryption mapping"** at first boot, because `encrypt` is always among the initramfs hooks. Row D checked the command line, not the console. Upstream omacom/omarchy-iso#143 (open, mergeable) removes the hook on unencrypted installs. Candidate: carry it like #11388.
  - **Smaller oddities, not yet looked into:**
    - the install log writes vconsole.conf with an empty keymap although install.toml said `keyboard = "us"`
    - `installed_packages` is 953 against 952 expected
    - a stray `offline.db` is left in the sync directory
    - with no network, `pacman-init` waits for time sync, so the keyring setup lands mid-wizard

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
