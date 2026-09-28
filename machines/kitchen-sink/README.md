# kitchen-sink: daily check-up and nightly updater

kitchen-sink is an Omarchy 4 desktop on the home LAN: Secure Boot on with our own keys, the kitchen build of `omarchy-dev` pinned with IgnorePkg, an encrypted btrfs root and an encrypted btrfs data drive at /mnt/data. This directory looks after it with three things:

- **A daily check-up** at 09:00. It only reads: Secure Boot, the pin, failed units, disk space, NVMe health, btrfs errors and scrubs, pending updates, the journal, and how last night's update went. It writes a report, logs to the journal and shows a toast.
- **Monthly btrfs scrubs** of / and /mnt/data, using the timers that come with btrfs-progs.
- **A gated nightly `omarchy update`**, tried at 02:30, 03:30, 04:30 and 05:30. It runs Omarchy's own `omarchy-update -y` only when nobody is using the machine and every safety and compatibility check passes, then checks that the machine will still boot. It never reboots. **It is installed switched off**, and stays off until it has been proven on this machine (see [Turning on the nightly updater](#turning-on-the-nightly-updater)).

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
- It does **not** enable `kitchen-update.timer`. If you have enabled it since, it stays enabled.
- It prints every file it installed, updated or left unchanged, and what to run next.

Running it again is safe; it changes only what differs. If you edited a file in /etc/kitchen-sink, yours is kept and the shipped version is written next to it as `<name>.new`; the installer prints the `diff -u` command to merge them. A file you never edited is simply updated: the installer remembers what it shipped in /var/lib/kitchen-sink/configs.sha256, the way pacman tells an edited config from an old one. It refuses to run while the check-up or an update is running.

| Installed | What it is |
| --- | --- |
| /usr/local/sbin/kitchen-checkup | the daily check-up |
| /usr/local/sbin/kitchen-update | the nightly updater (also `--dry-run`, `--grant-test`, `--revoke`, `--boot-check`) |
| /usr/local/lib/kitchen-sink/ | `notify` (the toast), `safe-to-update` (is anyone using the machine?), `preflight` and `postflight` (before and after the update), and the Python helpers `nvme-health.py`, `evwatch.py`, `news-check.py` |
| /etc/kitchen-sink/checkup.conf | the check-up's thresholds, every default shown commented out |
| /etc/kitchen-sink/journal-ignore.regex | journal errors known to be harmless |
| /etc/kitchen-sink/update.conf | the updater's settings and policies |
| /etc/systemd/system/kitchen-{checkup,update}.{service,timer} | the units |
| /etc/sysusers.d/kitchen-update.conf | the `kitchen-update` group, which never has members |
| /etc/tmpfiles.d/kitchen-update.conf | removes a leftover sudo grant at boot |

Both programs source their config file as root, so they ignore one that is not owned by root or that others can write to; the check-up says so in its report.

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
| WARN | look at it soon (low space, a reboot pending, the update held, no update for 3 nights, unexpected journal errors) |
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
2. **Activity:** nothing suggests you are using the machine. That means 10 minutes without keyboard or mouse input, 30 minutes without terminal or agent activity, and no SSH session, inhibitor, audio, fullscreen window, game, GPU or CPU load, download or VM.
3. **Compatibility:** the mirror is reachable; the update resolves; it would not replace the kitchen build; no Arch news since the last update; no AUR updates; no desktop-stack update the pinned build wasn't written for; not more than 21 days since the last update; enough space on / and the ESP; the filesystem is healthy.
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

   `force-idle` skips the activity check once. While the update runs, a low toast says so, and `systemd-inhibit --list` shows kitchen-update's `shutdown` inhibitor in `block` mode. Afterwards, check that `jq . /var/lib/kitchen-update/status.json` says DONE, that `omarchy secureboot status` and `sudo sbctl verify` are clean, that /etc/sudoers.d/98-kitchen-update is gone, that /tmp/omarchy-update.log belongs to kevinwyckoff, and that the toast arrived. Then reboot at the machine and confirm it boots with Secure Boot on. The first run brings limine-mkinitcpio-hook 1.40; if it words its log lines differently, the postflight fails safe with a false DO NOT REBOOT, and its markers in `lib/postflight` need updating before the timer goes on.
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

## Uninstall

```bash
sudo bash /tmp/kitchen-sink/uninstall.sh [--purge] [--disable-scrubs]
```

It turns both timers off, revokes any sudo grant and checks that it is gone (and kills any process still carrying the grant's group), then removes the programs, the units, /etc/kitchen-sink, the sysusers and tmpfiles snippets, the `kitchen-update` group, the check-up's package database cache and the installer's record in /var/lib/kitchen-sink. Running it again is safe. It refuses while an update is running.

- `--purge` also deletes the reports, logs and state in /var/log/kitchen-{checkup,update} and /var/lib/kitchen-{checkup,update}. Without it they stay.
- `--disable-scrubs` also turns off the monthly scrubs. They come with btrfs-progs and are worth keeping on their own, so they stay on by default.

It keeps the IgnorePkg pin in /etc/pacman.conf and the pre-refresh-pacman hook: they protect manual updates too, for as long as the kitchen build is installed.

## Tests

From Marvin, or any machine with Docker (nothing runs on kitchen-sink):

```bash
tests/all                    # everything
tests/all checkup install    # some parts
```

- `checkup`: the check-up's suites (`tests/run`), fed with real output from kitchen-sink, run as root and as an ordinary user.
- `update`: the updater's suites (`tests/update/run.sh`), each in its own container, with real sudo for the grant lifecycle (including a process that carries the group) and end-to-end nights against a faked desktop: DONE, FAILED, the boot-check record and its re-check, an escaped process, an AUR update under the guard, a missing snapshot, a stop mid-update, and a RUNNING left behind. The lint suite checks that the unit's timeouts cover the run's own limits.
- `install`: `install.sh` and `uninstall.sh` in a container booted with systemd. It covers owners and modes, running again, kept configs, the timers, both units run for real, the unit's timeouts under kitchen-sink's 5 s stop default, the shutdown inhibitor, a process that escapes into the user manager through `systemd-run --user --scope` (the check-up's FAIL, the next slot's kill), the check-up reading the updater's night, the grant test, the journal filter for its sudo probes, a leftover grant, and a clean removal that keeps the pin.
- `lint`: shellcheck over every shell script.
