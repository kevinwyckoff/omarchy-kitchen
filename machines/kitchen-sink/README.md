# kitchen-sink: daily check-up, nightly updater and thermal events

kitchen-sink is an Omarchy 4 desktop on the home LAN: Secure Boot on with our own keys, the kitchen build of `omarchy-dev` pinned with IgnorePkg, an encrypted btrfs root and an encrypted btrfs data drive at /mnt/data. This directory looks after it with four things:

- **A daily check-up** at 09:00. It only reads: Secure Boot, the pin, failed units, disk space, NVMe health, btrfs errors and scrubs, pending updates, the journal, the thermal events, and how last night's update went. It writes a report, logs to the journal and shows a toast.
- **Monthly btrfs scrubs** of / and /mnt/data, using the timers that come with btrfs-progs.
- **A gated nightly `omarchy update`**, tried at 02:30, 03:30, 04:30 and 05:30. It runs Omarchy's own `omarchy-update -y` only when nobody is using the machine and every safety and compatibility check passes, then checks that the machine will still boot. It never reboots. **It is installed switched off**, and stays off until it has been proven on this machine (see [Turning on the nightly updater](#turning-on-the-nightly-updater)). On kitchen-sink it passed those steps and has been on since 2026-09-30.
- **Thermal events**: `kitchen-thermal.service` turns what the fans, the board and CPU sensors, the system NVMe drive and the GTX 1650 signal into journal lines, `omarchy-hook thermal` hooks and a few toasts. No program polls the sensors, except where there is no other way, and then it says so (see [Thermal events](#thermal-events)).

Nothing leaves the machine: the reports, logs and state stay in /var/log and /var/lib.

## Install

From Marvin, copy this directory over (without its tests) and run the installer as root:

```bash
R=~/.config/omarchy-kitchen/remote/ssh.sh
cd ~/src/kitchen/omarchy-kitchen/machines
tar --exclude=kitchen-sink/tests -cf - kitchen-sink | $R 'rm -rf /tmp/kitchen-sink && tar -C /tmp -xf -'
$R --sudo "sudo -S -p '' bash /tmp/kitchen-sink/install.sh"
```

At the machine, `sudo bash install.sh` from a copy of this directory does the same.

What `install.sh` does:

- It installs the two programs to /usr/local/sbin and their helpers to /usr/local/lib/kitchen-sink (root:root 0755), and the units, the settings and the sysusers and tmpfiles snippets under /etc (root:root 0644).
- It creates the empty `kitchen-update` group and /run/kitchen-update.
- It enables and starts `kitchen-checkup.timer`, `btrfs-scrub@-.timer` and `btrfs-scrub@mnt-data.timer`.
- It enables and starts `kitchen-thermal.service`, and restarts it when a reinstall changed its program, unit or settings.
- It puts the sample thermal hooks in `~/.config/omarchy/hooks/thermal.d/` (the hook user's, `kevinwyckoff` unless thermal.conf's HOOK_USER says otherwise), writing them as that user. It never touches a hook of yours there.
- It says whether the patched nct6775 driver (`nct6775-notify-dkms`, a package of its own) is installed and loaded, and prints what to run if not. It never installs or loads a driver itself.
- It does **not** enable `kitchen-update.timer`. If you have enabled it since, it stays enabled.
- It prints every file it installed, updated or left unchanged, and what to run next.

Running it again is safe; it changes only what differs. If you edited a file in /etc/kitchen-sink, yours is kept and the shipped version is written next to it as `<name>.new`; the installer prints the `diff -u` command to merge them. Delete the `.new` once merged: like pacman's `.pacnew`, each shipped version is offered once, so later runs keep your file quietly until a newer one ships. A file you never edited is simply updated: the installer remembers what it shipped in /var/lib/kitchen-sink/configs.sha256, the way pacman tells an edited config from an old one. It refuses to run while the check-up or an update is running.

| Installed | What it is |
| --- | --- |
| /usr/local/sbin/kitchen-checkup | the daily check-up |
| /usr/local/sbin/kitchen-update | the nightly updater (also `--dry-run`, `--grant-test`, `--revoke`, `--boot-check`) |
| /usr/local/lib/kitchen-sink/ | `notify` (the toast), `safe-to-update` (is anyone using the machine?), `preflight` and `postflight` (before and after the update), `kitchen-thermald.py` (the thermal event daemon), and the Python helpers `nvme-health.py`, `evwatch.py`, `news-check.py` |
| /etc/kitchen-sink/checkup.conf | the check-up's thresholds, every default shown commented out |
| /etc/kitchen-sink/journal-ignore.regex | journal errors known to be harmless |
| /etc/kitchen-sink/update.conf | the updater's settings and policies |
| /etc/kitchen-sink/thermal.conf | the thermal daemon's levels, which NVMe drives to arm, hooks and toasts |
| /etc/systemd/system/kitchen-{checkup,update}.{service,timer} | the check-up's and the updater's units |
| /etc/systemd/system/kitchen-thermal.service | the thermal daemon |
| ~kevinwyckoff/.config/omarchy/hooks/thermal.d/*.sample | the sample thermal hooks, the user's own files |
| /etc/sysusers.d/kitchen-update.conf | the `kitchen-update` group, which never has members |
| /etc/tmpfiles.d/kitchen-update.conf | removes a leftover sudo grant at boot |

Both programs source their config file as root, so they ignore one that is not owned by root or that others can write to; the check-up says so in its report. The thermal daemon reads thermal.conf without running it, under the same rule.

## The daily check-up

It runs at 09:00 (up to 10 minutes later), or at the next boot if the machine was off. It takes well under a minute, changes nothing, and leaves:

- the report, `/var/log/kitchen-checkup/<date>.txt`, with `latest.txt` pointing at today's and `latest.json` holding the same results for scripts; reports are kept 90 days;
- one journal line per check, at a matching priority;
- a toast: low urgency when all is well, normal on a warning, critical on a failure (a critical toast stays until you dismiss it). Do Not Disturb is respected: the toast goes to the notification history instead. Clicking it opens the report. If nobody is logged in within 3 minutes, there is no toast, only the report and the journal.

Each check ends in one of four levels:

| Level | Means |
| --- | --- |
| OK | fine |
| INFO | worth knowing, nothing to do (updates pending, a newer Omarchy held back by the pin, a scrub running) |
| WARN | look at it soon (low space, a reboot pending, the update held, no update for 3 nights, unexpected journal errors, thermal events off or degraded, a thermal hook that failed) |
| FAIL | act now, and do not reboot until it is understood (Secure Boot not clean, a UKI or nvidia module that does not match the installed kernel, pacman cut off with its lock left, the pin missing, the update failed or was cut off, a leftover sudo grant or a process still carrying its group, drive or filesystem errors) |

The report lists every check; the toast shows the failures first, then the warnings.

### Reading it from Marvin

The report and the journal can be read without sudo:

```bash
R=~/.config/omarchy-kitchen/remote/ssh.sh
$R 'cat /var/log/kitchen-checkup/latest.txt'
$R "jq -r '.status, (.checks[] | select(.level != \"OK\") | \"\(.level) \(.check): \(.message)\")' /var/log/kitchen-checkup/latest.json"
$R 'journalctl -u kitchen-checkup -u kitchen-update -p warning --since yesterday --no-pager'
$R 'ls /var/log/kitchen-checkup/'
```

To run a check-up now: `$R --sudo "sudo -S -p '' kitchen-checkup --no-notify"`. It also takes `--quiet` (only WARN and FAIL) and `--json`. Its exit status is 0 for OK, 1 for WARN, 2 for FAIL, and 3 if the check-up itself broke.

## The nightly updater

### How a night goes

Each slot runs these steps in order, and stops at the first one that says no:

1. **Static gates:** you are logged in; the pin is in place; the Omarchy internals the updater relies on are unchanged; no Omarchy migrations are pending; Secure Boot is clean; updates are pending.
2. **Activity:** nothing suggests you are using the machine. That means 10 minutes without keyboard or mouse input, 30 minutes without terminal or agent activity, and no SSH session, inhibitor, audio, fullscreen window, game, GPU or CPU load, download or VM. A video wallpaper is not you: while the GPU is measured (5 s), owe's wallpaper is paused, then resumed. A pause owe already had stays.
3. **Compatibility:** the mirror is reachable; the update resolves; it would not replace the kitchen build; no Arch news since the last update; no AUR updates; no desktop-stack update the pinned build wasn't written for; not more than 21 days since the last update; enough space on / and the ESP; the filesystem is healthy. On the ESP, a UKI rebuild needs the largest boot file plus 64 MiB free (about 335 MiB). Each update's pre-update snapshot keeps its own copy of the UKI (about 271 MiB), so kitchen-sink's `/etc/limine-snapper-sync.conf` caps the ESP at `LIMIT_USAGE_PERCENT=65`, down from 85. With `MAX_SNAPSHOT_ENTRIES` on `auto`, the oldest snapshot boot entries are dropped to stay under it, which keeps more than the check-up's 700 MiB free.
4. **The sudo grant** is written and tested (see [below](#the-sudo-grant-in-plain-words)).
5. **`omarchy-update -y`** runs as you, so Omarchy's snapshot, migrations, hooks, shell restart and Secure Boot re-signing all happen as they would at the desk. While it runs, `status.json` says RUNNING, a low toast says an update is running, and logind holds off restart and power off from the desktop (see [While it runs](#while-it-runs)).
6. **The grant is revoked**, and the updater checks that it is gone. Any process the update left carrying the grant's group is killed (see [the sudo grant](#the-sudo-grant-in-plain-words)).
7. **Postflight:** the transaction completed, each new UKI was built, signed and copied, the kernel and nvidia module match, and Secure Boot and `sbctl verify` are clean. It warns when Omarchy carried on without its pre-update snapshot.
8. **Reboot check:** it notes whether a reboot is needed or recommended. It never reboots; the LUKS passphrase is typed at the machine anyway.

Every night ends in one state, in `/var/lib/kitchen-update/status.json` and the journal:

| State | Means | Next |
| --- | --- | --- |
| BUSY | the machine was in use, or the mirror was down | the next slot tries again |
| DEFERRED | the last slot was busy too | tomorrow night |
| UP-TO-DATE | nothing to install | nothing |
| HELD | a safety or compatibility gate said no; nothing changed | read why in the morning report; most holds clear once you run `omarchy update` yourself |
| DONE | updated, and every check afterwards passed | a toast says whether to reboot |
| FAILED | the update started, then failed or failed its checks, or was cut off before it could say | a critical toast; it says DO NOT REBOOT when the boot chain is involved, and what to do about it |

DONE and FAILED toast at night, and so does the start of the update itself (low urgency). The 09:00 check-up reports on every night, warns when 3 nights in a row passed without an update while updates were pending, and turns a DONE night into a WARN when the updater flagged something to look at (no pre-update snapshot, a process it had to kill).

The full record of a night, including every gate and Omarchy's own output, is `/var/log/kitchen-update/<date>.log`. `history.jsonl` next to `status.json` keeps the last 400 status writes.

### When the boot checks fail

A night whose postflight fails a boot check (pacman, the UKI, the kernel, the nvidia module, DKMS, Secure Boot or the ESP) says DO NOT REBOOT, and names the remedy for what failed: `sudo dkms autoinstall -k <kernel>` then `sudo limine-mkinitcpio` for a missing nvidia module, `sudo limine-mkinitcpio` for a stale or unsigned UKI, and so on. A clean `omarchy secureboot status` alone is not the all-clear: a missing nvidia module or a stale UKI leaves it clean.

That verdict outlives the night. The updater keeps it in `/var/lib/kitchen-update/boot-check`, and every later slot re-runs the same live boot checks first: while they fail, the night is HELD, even when there is nothing to install; once they pass, the record is removed and the night goes on. The check-up reports FAIL, do not reboot, for as long as the record exists, and only calls a reboot safe when Secure Boot is clean and the UKI on the ESP matches every installed kernel. After fixing it at the machine, `sudo kitchen-update --boot-check` re-runs the checks at once and clears the record if they pass.

A run cut off after the update started (stopped, killed, a crash or a power cut) leaves the same record, since its boot checks never ran.

### While it runs

- **Restart and power off are held off.** Omarchy's own inhibitor covers sleep and idle only, and a reboot stops pacman's scope with SIGTERM, which pacman does not catch: it would die mid-transaction. So from the start of the update until the postflight has seen pacman finish, the updater holds a logind shutdown inhibitor in block mode. logind then refuses a restart or power off asked for from your session, the power menu's included, unless it is authorized to ignore inhibitors (Omarchy's menu asks for no password, so it fails, though it still closes your windows first). `sudo systemctl reboot` goes through regardless; don't.
- **A low toast says an update is running**, and it stays in the notification history.
- **The grant is gone before any AUR build.** Omarchy's last phase updates AUR packages with yay, and its sudo wrapper would still match the grant. The preflight holds the night when AUR updates are pending, and if one appears in the hour between, the updater removes the grant the moment that phase's header appears, before yay asks the AUR anything. The build then asks for a password nobody types, and the night ends FAILED saying why.

### Vetoing a night

- **For tonight, at the machine:** leave `systemd-inhibit --what=idle --why="no update tonight" sleep 12h` running in a terminal. Any block-mode inhibitor makes every slot BUSY while it runs; Ctrl+C ends it. An SSH session left open has the same effect.
- **Until you say otherwise:** `sudo systemctl stop kitchen-update.timer`. `sudo systemctl start kitchen-update.timer` resumes it, and so does a reboot while it is enabled. From Marvin: `$R --sudo "sudo -S -p '' systemctl stop kitchen-update.timer"`.
- **For good:** `sudo systemctl disable --now kitchen-update.timer`.
- **Stop a run in progress:** `sudo systemctl stop kitchen-update.service`. pacman is safe: Omarchy runs it in its own scope, so it finishes its transaction whatever happens to the rest. systemd signals only the updater, which revokes the grant and records the night at once; the unit gives it up to 3 minutes (its own TimeoutStopSec, not kitchen-sink's 5 s default), then kills what is left, and the stop hook runs. If the update had started, the night is recorded as FAILED either way: `status.json` says RUNNING from the start of the update, and the stop hook turns a RUNNING nobody finished into FAILED, even when the grant is already gone. The same happens when a run hits the unit's 3 h 30 min limit, and the next slot does it after a crash or a power cut. Read the day's log before rebooting; the boot checks run again at the next slot (or with `sudo kitchen-update --boot-check`).

### Turning on the nightly updater

It stays off until these steps have passed on kitchen-sink:

1. **Dry run:** `sudo kitchen-update --dry-run --quiet-secs 60`. Every read-only gate runs for real, and it prints its verdict, the sudo rule it would write, and the exact environment and command it would run. It grants nothing, installs nothing and writes nothing. Run over SSH, it lists your own SSH session and terminal as reasons it is busy, marked as its own; the real run has neither. So over SSH its verdict is BUSY, or DEFERRED after 05:30.
2. **Negative dry runs:** each of these should make the dry run say BUSY: a second SSH session; `systemd-inhibit --what=idle --mode=block sleep 300`; a key pressed during the 60 s input window. After 05:30 (the last slot) the verdict reads DEFERRED instead, which is busy too: at that hour a real run would have no slot left tonight.
3. **Grant test:** `sudo kitchen-update --grant-test` must end with `grant test: passed`. It proves on this machine that the update's process tree gets sudo and your own processes do not, that `newgrp kitchen-update` is refused, and that the rule is gone afterwards.
4. **One supervised real run**, ideally at the machine:

   ```bash
   sudo touch /run/kitchen-update/force-idle && sudo systemctl start --no-block kitchen-update.service
   journalctl -fu kitchen-update
   ```

   `force-idle` skips the activity check once. While the update runs, a low toast says so, and `systemd-inhibit --list` shows kitchen-update's `shutdown` inhibitor in `block` mode. Afterwards, check that `jq . /var/lib/kitchen-update/status.json` says DONE, that `omarchy secureboot status` and `sudo sbctl verify` are clean, that /etc/sudoers.d/98-kitchen-update is gone, that /tmp/omarchy-update.log belongs to kevinwyckoff, and that the toast arrived. Then reboot at the machine and confirm it boots with Secure Boot on. If a new limine-mkinitcpio-hook words its log lines differently, the postflight fails safe with a false DO NOT REBOOT, and its markers in `lib/postflight` need updating before the timer goes on. 1.40, the version the first run brought, kept them.
5. **Turn it on:** `sudo systemctl enable --now kitchen-update.timer`, then `systemctl list-timers kitchen-update.timer` shows the next slot. Read the morning reports for the next few nights.

### Settings

`/etc/kitchen-sink/update.conf` holds the thresholds of the activity check and the policies. The main choices:

- `BOOT_CHAIN_POLICY=install` installs kernel, nvidia and boot-chain updates at night behind the strict postflight. `defer` holds those nights for an attended update instead.
- `NEWS_POLICY=hold-all` holds on any Arch news item since the last update.
- `DRIFT_REGEX` names the desktop-stack packages that are held while the pin holds `omarchy-dev` back.

## The sudo grant, in plain words

`omarchy update` has to run as you, and it calls sudo many times. At 3 a.m. nobody is there to type the password, so the updater gives that one run temporary root rights, and takes them back right after.

For each run it writes a sudo rule that says: members of the `kitchen-update` group may run anything as root without a password, until two hours from now. Nobody is a member of that group, and nobody can join it: it has no members and no password. The updater starts `omarchy update` with that group added to that one process and whatever it starts. sudo checks the group list of the process asking, so only the update gets root. Your desktop, your terminals, Claude, Pi and SSH logins do not. The grant test proves this on the machine before the first real run.

When the run ends, the rule is deleted and the updater checks that sudo refuses again. If anything interrupts that, there are three backstops: the service's stop hook deletes the rule, the rule expires by itself after two hours, and a boot-time cleanup deletes it. If a rule is ever left behind, the morning check-up reports FAIL.

**The group is the key, so every process that carries it is part of the grant.** The service's cgroup does not hold them all. Anything the update starts through your user manager (`uwsm app`, `systemd-run --user --scope`, and so Omarchy's `omarchy-restart-app`, which the update uses to restart apps that asked for it) is moved into your session, keeps the group, and survives the end of the service. The next night's rule would give such a process root, and the grant test could not see it. So containment rests on a scan of every process, not on the cgroup: the updater writes the rule only while no process carries the group; once the update is over it kills every process that still does, and the stop hook and the next slot check again. The morning check-up reports FAIL if one exists outside a run. The update's own process tree also never inherits the updater's run lock, so a process that outlived a run can't stop the next nights.

**The trade-off:** during the run, everything the update runs as you gets root without a password. That includes Omarchy's own scripts, your post-update hooks in `~/.config/omarchy/hooks/`, and mise tool installs. An `omarchy update` at the desk gives them the same power through your cached sudo. The difference is that nobody is watching. If something malicious ever ran as your user, it could plant a hook and get root the next night, without the password prompt that would otherwise stop it. No third-party build script runs under the grant: pending AUR updates hold the night, and the grant is removed the moment Omarchy's AUR phase starts (see [While it runs](#while-it-runs)). If that trade is not acceptable, keep the timer off and update by hand; the check-up alone needs no grant at all.

## Thermal events

`kitchen-thermal.service` runs `kitchen-thermald.py` as root. It waits in one `poll()` for what the hardware and the kernel already signal: kernel uevents, wake-ups on the Super I/O's sysfs files, NVML events from the GPU, and the kernel log. It turns each into an event:

- a journal line (`journalctl -t kitchen-thermal`), with `KITCHEN_EVENT`, `KITCHEN_STATE` and one `KITCHEN_<KEY>` field per key;
- a hook, `omarchy-hook thermal <event> <state> key=value...`, run as you in your own session;
- for a short list, a toast.

Its own view is in `/run/kitchen-thermal/state.json` (`kitchen-thermald.py --dump-state` prints it): each source's mode (`event`, `degraded` or `off`) and why, the CPU and NVMe levels, and the last events. `systemctl status kitchen-thermal` shows the same in one line.

The daemon never writes a Super I/O limit, pwm or SmartFan setting (`tempN_max`, `max_hyst` and `crit`, `in*_max`, `pwm*`, `pwm*_enable`, `fanN_min`). The fans stay under the chip's SmartFan control. Its only writes are the temperature thresholds and the AEN setting of the NVMe drives named in `NVME_ARM`. Those are volatile: the drive forgets them at a reset, and the daemon puts the drive's own thresholds back when it stops, or when a reload takes the drive out of `NVME_ARM`.

The unit keeps root only for the NVMe ioctls and writes, and for starting hooks in your manager. It keeps no capability but `CAP_SYS_ADMIN`, sees the file system read-only except /sys, /dev and its runtime directory, cannot see /home or /run/user, and a system call filter refuses mount calls, so that `CAP_SYS_ADMIN` cannot undo the rest. Whether your manager is up, it asks PID 1 (`systemctl is-active user@<uid>.service`), which answers inside the sandbox. Before the daemon starts, the unit runs NVIDIA's `nvidia-modprobe -c255 -c0` outside the sandbox, to make `/dev/nvidiactl` and `/dev/nvidia0`. NVML needs them, nothing makes them at boot until the first NVIDIA program runs, and the sandbox refuses the setuid helper NVML would use to make them itself.

### What is and isn't a hardware interrupt

| Source | How an event arrives | An interrupt? |
| --- | --- | --- |
| System NVMe (FireCuda 520) | The drive compares its own temperature with the thresholds the daemon set. It completes an Asynchronous Event Request (an MSI-X interrupt), and the kernel sends the uevent `NVME_AEN=0x020101` | **Yes**, from the drive |
| Data NVMe (WDC) | Nothing: the stock kernel keeps no Asynchronous Event Request outstanding on it (case B, below) | No events. The check-up still reads its temperature every morning |
| GTX 1650 | NVML events from the GPU firmware: Xid errors, the GPU lost, recovery, P-state and clock changes | **Yes**, for those. There is no GPU temperature event at all: `gpu-hot` and `gpu-throttle` are read at each wake-up. While the GPU is busy or still hot, the wait also times out every 15 s (5 s while throttling); at idle it never does |
| Super I/O NCT6799D: board temperatures, fans, pwm, and the CPU's own temperature over SB-TSI (TSI0) | The patched nct6775 samples the chip **inside the kernel** every `notify_interval` (1 s). It sends a uevent for an alarm, and wakes `poll()` when a pwm, fan or temperature moves | **No**. The kernel polls; no program polls the chip. About 1 s of delay. Once a minute the daemon re-reads the driver's four parameters, since switching notification off at runtime signals nothing |
| The same, without the patched nct6775 (a kernel outside its range) | The daemon reads the same files every 10 s and reports `thermal-monitor degraded` | **No**: a program polls, and says so |
| Kernel log | NVRM Xid, "fallen off the bus" and amdgpu critical-temperature lines, followed through the journal | A backstop for the GPU events |
| CPU `k10temp`, DIMM `spd5118`, the Radeon iGPU | Not watched. They have no event source; the CPU is covered through the Super I/O's TSI0 | - |

The NCT6799D can route a real hardware-monitor interrupt to an ISA IRQ, but nothing on this board sets it up. Trying it means changing Super I/O and chipset settings that also drive SMI# and the over-temperature shutdown pin, so it has not been tried. The patched driver only adds a read-only register dump for looking (`nct6775.dump=1`, in debugfs). On this board it shows no IRQ assigned (logical device 0B CR70 is 0) and the shared pin in SMI# mode, so the firmware owns it.

### The events

| Event | States | Keys | When |
| --- | --- | --- | --- |
| `cpu-hot` | start, change, end | `level=warn\|crit temp threshold sensor` (`held=60` once crit has held 60 s) | TSI0 at 90 °C (warn) or 95 °C (crit) for 10 s. It clears 5 °C below. A 7700X boosts to 95 °C by design, so only a crit that holds for 60 s toasts |
| `board-hot` | start, end | `sensor=tempN label temp max hyst` | The chip's own limit alarms, with the limits the BIOS set. temp7 (a CPU stand-in at 80/75 °C) goes to the journal only |
| `fan-ramp` | change | `pwm=pwmN pct dir=up\|down rpm src` | Once per 10 % of pwm, at most once every 5 s per fan |
| `fan-stall` | start, end | `fan=fanN pwm pct rpm` | A fan at 0 rpm for 5 s while its pwm is at least 20 % |
| `nvme-hot` | start, change, end | `drive=system level=warn\|crit temp` | The system drive at 70 °C (warn) or 80 °C (crit), cleared below 65 °C (the data drive's levels are 65/75/60, if it ever gets events) |
| `nvme-health` | info | `drive kind=reliability\|spare` | Only if `NVME_AEN_MASK` asks for them |
| `gpu-throttle` | start, change, end | `reason temp pstate` | A throttle counter moved. It ends after 30 s without one |
| `gpu-hot` | start, end | `temp` | 85 °C; it clears 5 °C below |
| `gpu-xid` | info | `code kind=xid\|unavailable\|recovery\|lost\|ctf gpu=nvidia\|amdgpu` | From NVML, or the kernel log when NVML cannot say. `ctf` is amdgpu's critical-temperature line, just before it shuts the machine down |
| `thermal-monitor` | degraded, restored | `source reason` | A source stopped sending events (it falls back to polling), or came back |

Toasts go through the same `notify` as the check-up's, so Do Not Disturb holds them. By default only these toast: `fan-stall`, `nvme-hot` crit, `cpu-hot` crit held 60 s, `gpu-xid`, and `thermal-monitor` degraded. Each toasts at most once per 10 minutes per event and sensor. Everything else goes to the journal and the hooks.

### Writing a hook

A hook is a bash file in `~/.config/omarchy/hooks/thermal.d/` (or a single `~/.config/omarchy/hooks/thermal`). `omarchy-hook` runs each file in that directory in name order, skipping `*.sample`. The two samples show the pattern: `10-toast.sample` adds toasts for events the daemon does not toast, and `20-log.sample` keeps your own event log. To use one, copy it without `.sample`.

- It is called with `<event> <state> key=value...`, for example `cpu-hot start level=warn temp=91 threshold=90 sensor=tsi0`. The whole event is also in `$KITCHEN_THERMAL_EVENT` as JSON.
- It runs as you, in your own systemd user manager (`systemd-run --user`), so notifications, `$HOME` and your Wayland session work as in any Omarchy hook. With nobody logged in (no `user@<uid>.service` running), hooks are skipped, and said so in the journal (`KITCHEN_HOOK=no-user-manager`); the check-up counts them.
- It gets at most 60 s. Hooks run one at a time and never hold up the daemon.
- At most 30 hooks run a minute, and 12 per event and sensor; the rest are only journalled. A hook that saw a `start` always sees its `end`.
- To try a hook without waiting for heat: `sudo /usr/local/lib/kitchen-sink/kitchen-thermald.py --test-event cpu-hot start level=warn temp=91`. With the service running, the running daemon delivers it, from inside its sandbox, through the real journal (at notice priority at most, so the check-up does not count it as an error), hook and toast, marked as a test, and the command waits for the hook's and toast's results (`delivered by kitchen-thermal.service`). That is the check after a deploy. Without the service, or with `--local` before `--test-event`, the shell delivers it itself and says so: that tries a hook, but proves nothing about the service, whose sandbox the shell does not have.
- A hook that fails shows in the morning check-up as a WARN, with its name. The daemon logs a hook that timed out; `omarchy-hook` itself logs `Hook failed: <file>` for a script that exits non-zero. Read them with `journalctl -t kitchen-thermal -t omarchy-hook --since -24h`.

A hook may do anything you can do: renice a build, pause a download, change a fan curve. The daemon itself never touches the fans.

### Vetoing and tuning

- **Levels, drives, toasts, hooks:** `/etc/kitchen-sink/thermal.conf` lists every setting with its default, commented out. Change a line, then `sudo systemctl reload kitchen-thermal`: it re-reads the file and arms the NVMe drives again. The ones worth knowing:
  - `CPU_WARN`, `CPU_CRIT`, `CPU_HYST` and `CPU_DWELL_SECS`;
  - `NVME_ARM` and `NVME_<role>_WARN`, `_CRIT`, `_CLEAR`. They must be in order, CLEAR < WARN < CRIT, within 0 to 120 °C, and `NVME_HOT_HYST` 1 to 30: out of order they would program a threshold that fires at once, so the daemon warns and leaves a drive with that role unarmed;
  - `GPU_HOT` and `GPU_IDLE_HEARTBEAT` (0: never wake an idle GPU);
  - `FAN_WATCH` (the fans that must spin);
  - `NOTIFY_EVENTS` (empty: no toasts at all);
  - `HOOKS=0` (no hooks) and `HOOK_RATE_PER_MIN`.
- **One hook:** rename it back to `<name>.sample`.
- **Everything, until the next boot:** `sudo systemctl stop kitchen-thermal`. **For good:** `sudo systemctl disable --now kitchen-thermal`. The check-up then reports a WARN every morning, since nothing watches the temperatures.
- **The driver's sampling:** the package's defaults are in `/usr/lib/modprobe.d/nct6775-notify.conf`: `notify_interval=1000` ms, `notify_pwm_delta=3` and `notify_temp_delta=1000` (1 °C, so the CPU's reading wakes the daemon). The driver's own default is 0, off, so that file is what switches it on. Copy it to /etc/modprobe.d to change them for good. To change them now, write to `/sys/module/nct6775_core/parameters/`; the driver takes a new `notify_interval` at once and clamps it to 250-10000 ms. `notify_interval=0` turns the driver's notifications off; within a minute (or at once with `sudo systemctl reload kitchen-thermal`) the daemon notices, polls, and says it is degraded.

### The NVMe drives

The stock 7.2.5 kernel switches off the drives' SMART events, the temperature one included, at every controller start. Whether the daemon can switch them back on without a rebuilt kernel depends on the drive's controller.

At each start the kernel sets the Asynchronous Event Configuration (feature 0Bh) to the notices it knows (OAES bits 8, 9, 11 and 31). It keeps one Asynchronous Event Request outstanding only if the controller advertises at least one of them. Otherwise it returns before submitting any request, and no event of any kind can arrive.

- **Case A**: at least one of those bits is set. The daemon only has to set bit 1 (temperature) of feature 0Bh again after each controller start. No rebuild.
- **Case B**: none of them. Events need a rebuilt nvme-core, the root disk's driver. That is not done: a bad build leaves the machine unbootable.

`sudo python3 /usr/local/lib/kitchen-sink/nvme-health.py --probe` says which case each drive is. It sends only Identify and Get Features, and refuses any other command before opening the drive. On kitchen-sink it said (2026-09-29, kernel 7.2.5-4):

| Drive | OAES | Feature 0Bh | Over / under threshold, drive default | Case |
| --- | --- | --- | --- | --- |
| system, FireCuda 520 (NVMe 1.3) | 0x200 (firmware-activation notices) | 0x200, exactly what the kernel wrote | 90 °C (its WCTEMP) / -60 °C | **A**: arm it |
| data, WDC WDS512G1X0C (NVMe 1.2) | 0 | 0: the kernel never wrote it | 85 °C (its WCTEMP) / off | **B**: no events |

So on this machine thermal.conf should say `NVME_ARM="system"`, and since 2026-10-01 it does. A threshold test then saw the drive's temperature AEN in both directions (see `docs/decisions.md`). With a drive armed, its critical-warning bit 1 (temperature) goes up whenever the drive passes a threshold the daemon lowered. The check-up treats that bit as a WARN, not a FAIL, for an armed drive still below its own limit, and a FAIL together with any other warning bit. Past its own limit (WCTEMP) the daemon moves the drive's over threshold out of reach, so no more events come, and bit 1 clears. For an armed drive the check-up therefore goes by the temperature: a FAIL at or above the drive's limit, or when the drive counted minutes above it (`warn_temp_minutes`) since the last check-up.

### The patched nct6775

The Super I/O's events need the stock nct6775 driver with a patch that samples the chip inside the kernel and signals changes. `pkg/nct6775-notify-dkms` builds it as a DKMS package for the 7.2 kernels (`BUILD_EXCLUSIVE_KERNEL="^7\.2\."`). The package installs it into `/usr/lib/modules/<kernel>/updates/dkms`, where it takes precedence over the in-tree copy.

- It is not in the UKI, so the signed boot chain does not change. Like nvidia's, the module carries no trusted signature, which is fine while signatures are not enforced.
- It is installed apart from `install.sh`, with `pacman -U`. Build it with `makepkg` in that directory (it checks the vendored sources against the release first), for example on kitchen-sink in the copy `install.sh` ran from. Then:

  ```bash
  sudo pacman -U nct6775-notify-dkms-*.pkg.tar.zst
  sudo modprobe -r nct6775 nct6775_core && sudo modprobe nct6775
  ```

  The reload takes the sensors away for a moment and may renumber hwmonN. The fans stay under SmartFan control meanwhile. A reboot does the same.
- **Undo:** `sudo pacman -R nct6775-notify-dkms`, then the same reload. The in-tree driver comes back.
- **Kernel updates:** DKMS rebuilds the module for every new 7.2 kernel before the UKI is built. On a kernel outside its range (7.3, say) it is skipped without an error: the machine boots the in-tree driver, and the daemon polls and reports `thermal-monitor degraded`. `pkg/nct6775-notify-dkms/refresh.sh` moves the package to a new kernel release.
- **Stable fixes:** every 7.2 kernel gets the vendored 7.2.5 sources, which would hide a stable fix to the driver in a later 7.2 release. The package records the newest release whose driver files `refresh.sh` found identical (`checked-through`, 7.2.8 now). A kernel newer than that is an `info` line in the preflight and in the check-up's `nct6775` row: run `refresh.sh <release> --record` (or `--update` if the files changed).

The nightly updater and the check-up follow it:

- **Preflight:** a pending kernel outside the package's range is an `info` line saying events will be off after the reboot, and so is one in range but newer than the release the package was checked against. Neither holds the update.
- **Postflight:** a failed `nct6775-notify` DKMS build is a WARN, not a FAIL (`DKMS_WARN_ONLY` in update.conf); nvidia's stays a FAIL. A new check, `thermal`, says for each installed kernel whether the patched module is built for it, and warns "events off for <kernel>" when not.
- **Check-up:**
  - `thermal`: the daemon is running, and each source's mode (a degraded source is a WARN, and so is one the daemon announced degraded that is still off: a lost GPU, a kernel-log follower that keeps failing, a Super I/O gone for good);
  - `nct6775`: the patched driver is the one loaded, with `notify_interval` (a WARN otherwise, with what to run; an INFO on a kernel newer than its sources were checked against);
  - `nvme-arm-<role>`: for each drive in `NVME_ARM`, read by the probe, that it is case A, armed (feature 0Bh bit 1), and has a threshold the daemon set;
  - `thermal-events`: the last 24 hours' events and hook failures, and the hooks skipped because nobody was logged in (an INFO when not one hook ran all day, which is also what a service that cannot see your session would look like).

### Upstream

The nct6775 patches are local patches, carried in `pkg/nct6775-notify-dkms` (so would a future nvme one be). They are to be offered upstream, with the notification off by default, together with the other held upstream PRs, only once this work is done. Nothing has been sent. If upstream takes them, the package can go.

## Uninstall

```bash
sudo bash /tmp/kitchen-sink/uninstall.sh [--purge] [--disable-scrubs] [--purge-driver]
```

It turns both timers and the thermal daemon off, revokes any sudo grant and checks that it is gone (and kills any process still carrying the grant's group). Then it removes the programs, the units, /etc/kitchen-sink, the sysusers and tmpfiles snippets, the `kitchen-update` group, the check-up's package database cache and the installer's record in /var/lib/kitchen-sink. It also removes the sample thermal hooks, as their user; your own hooks in that directory stay. Running it again is safe. It refuses while an update is running.

- `--purge` also deletes the reports, logs and state in /var/log/kitchen-{checkup,update} and /var/lib/kitchen-{checkup,update}. Without it they stay.
- `--disable-scrubs` also turns off the monthly scrubs. They come with btrfs-progs and are worth keeping on their own, so they stay on by default.
- `--purge-driver` also removes `nct6775-notify-dkms` with `pacman -R`. It was installed on its own, so it stays by default. The patched module already loaded stays until `sudo modprobe -r nct6775 nct6775_core && sudo modprobe nct6775` or a reboot.

It keeps the IgnorePkg pin in /etc/pacman.conf and the pre-refresh-pacman hook: they protect manual updates too, for as long as the kitchen build is installed.

## Tests

From Marvin, or any machine with Docker (nothing runs on kitchen-sink):

```bash
tests/all                    # everything
tests/all checkup install    # some parts
```

- `checkup`: the check-up's suites (`tests/run`), fed with real output from kitchen-sink, run as root and as an ordinary user. They include `nvme-health.py`'s probe: its allowlist of admin commands (every other opcode, log page, Identify CNS and feature is refused before the device is opened), the case A/B verdict, and a fake drive that reproduces kitchen-sink's real probe.
- `update`: the updater's suites (`tests/update/run.sh`), each in its own container, with real sudo for the grant lifecycle (including a process that carries the group) and end-to-end nights against a faked desktop: DONE, FAILED, the boot-check record and its re-check, an escaped process, an AUR update under the guard, a missing snapshot, a stop mid-update, and a RUNNING left behind. The lint suite checks that the unit's timeouts cover the run's own limits.
- `install`: `install.sh` and `uninstall.sh` in a container booted with systemd. It covers owners and modes, running again, kept configs, the timers, both units run for real, the thermal daemon started, restarted when its files change and read by the check-up, its hooks delivered from inside the real unit's sandbox with the user's manager up (a real event's, and a `--test-event` the running service delivers), the sample hooks written as their user, the unit's timeouts under kitchen-sink's 5 s stop default, the shutdown inhibitor, a process that escapes into the user manager through `systemd-run --user --scope` (the check-up's FAIL, the next slot's kill), the check-up reading the updater's night, the grant test, the journal filter for its sudo probes, a leftover grant, and a clean removal that keeps the pin.
- `lint`: shellcheck over every shell script.
- `thermal`: the thermal daemon (`tests/thermal/run`) against a fake sysfs with kitchen-sink's real nct6799 attributes, fake uevents, poll() wake-ups, NVMe admin commands and NVML (also through a fake libnvidia-ml in C), as root and as an ordinary user, and `systemd-analyze verify` on its unit. Besides levels, pairing, rate limits and delivery, it covers the device reloaded under the daemon with its uevents lost (at another hwmonN, and at the same one with stale descriptors), `notify_interval` switched off at runtime, a reload while degraded, `--once` changing nothing on a drive it would arm, NVMe levels out of order, a drive taken out of `NVME_ARM`, a GPU cooling at P8, kernel-log lines faked by device names, and `--test-event` handed to the running daemon.
- The patched nct6775 has its own suite, `pkg/nct6775-notify-dkms/tests/run.sh` (its README, Tests).
