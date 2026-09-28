#!/bin/bash
# shellcheck source-path=SCRIPTDIR

# install.sh and uninstall.sh end to end, as root in a throwaway Arch container
# booted with systemd (tests/install/run.sh starts one). Everything is real:
# files, owners and modes, systemd-sysusers and systemd-tmpfiles, daemon-reload,
# the timers, the check-up and the updater under their own units, the journal,
# and the sudo grant test. Only the desktop is missing, so the updater holds at
# its first gate and the toasts find no session.

set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
SRC=${SRC:-$(readlink -f "$HERE/../..")}
# shellcheck source=../update/lib.sh
source "$SRC/tests/update/lib.sh"

if [[ ! -e /.dockerenv || $(cat /proc/1/comm) != "systemd" ]]; then
  echo "test-install.sh installs into / and needs systemd as PID 1: run it through tests/install/run.sh" >&2
  exit 2
fi

USER_NAME=kevinwyckoff
K=/tmp/kitchen-sink
TODAY=$(date +%F)
BINS=(kitchen-checkup kitchen-update)
LIBS=(notify safe-to-update preflight postflight nvme-health.py evwatch.py news-check.py)
CONFIGS=(checkup.conf update.conf journal-ignore.regex)
UNITS=(kitchen-checkup.service kitchen-checkup.timer kitchen-update.service kitchen-update.timer)
INSTALLED=(/usr/local/sbin/kitchen-checkup /usr/local/sbin/kitchen-update /usr/local/lib/kitchen-sink
  /etc/kitchen-sink /etc/sysusers.d/kitchen-update.conf /etc/tmpfiles.d/kitchen-update.conf
  /etc/systemd/system/kitchen-checkup.service /etc/systemd/system/kitchen-checkup.timer
  /etc/systemd/system/kitchen-update.service /etc/systemd/system/kitchen-update.timer
  /var/lib/kitchen-sink)

run_install() { out=$(bash "$K/install.sh" "$@" 2>&1); rc=$?; }
run_uninstall() { out=$(bash "$K/uninstall.sh" "$@" 2>&1); rc=$?; }
owner_mode() { stat -c '%U:%G %a' "$1" 2>/dev/null; }
enabled() { systemctl is-enabled "$1" 2>/dev/null; }
show() { printf -- '---- %s\n%s\n---- end\n' "$1" "$2"; }

# ---- the machine: kitchen-sink's user, sudo rule, pin and pin hook
id "$USER_NAME" >/dev/null 2>&1 || useradd -m -u 1000 -G wheel "$USER_NAME"
echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel
grep -q '^IgnorePkg = omarchy-dev' /etc/pacman.conf ||
  sed -i '/^\[options\]/a IgnorePkg = omarchy-dev omarchy-settings-dev' /etc/pacman.conf
pacman_conf_sum=$(sha256sum /etc/pacman.conf)
hook=/home/$USER_NAME/.config/omarchy/hooks/pre-refresh-pacman.d/10-kitchen-pin
install -d -o "$USER_NAME" -g "$USER_NAME" "${hook%/*}"
printf '#!/bin/bash\n' >"$hook"

# The copy install.sh runs from, as the README's tar over ssh leaves it:
# without tests/, owned by the user.
rm -rf "$K"
mkdir -p "$K"
tar -C "$SRC" --exclude=./tests -cf - . | tar -C "$K" -xf -
chown -R "$USER_NAME:" "$K"

# ---- refusals, before anything is installed
run_install --bogus
expect_rc "install.sh: an unknown argument is refused" 2 "$rc" "$out"
out=$(runuser -u "$USER_NAME" -- bash "$K/install.sh" 2>&1)
rc=$?
expect_rc "install.sh: refuses without root" 1 "$rc" "$out"
expect_match "install.sh: and says why" "run as root" "$out"
# runuser's PAM session started the user's systemd manager, and with it a
# session bus with no desktop behind it. Stop it, so what follows runs as on a
# machine where nobody is logged in: no bus at all.
systemctl stop "user@$(id -u "$USER_NAME").service"
for _ in {1..20}; do
  [[ -e /run/user/$(id -u "$USER_NAME")/bus ]] || break
  sleep 0.5
done

mv "$K/lib/notify" "$K/lib/notify.away"
run_install
mv "$K/lib/notify.away" "$K/lib/notify"
expect_rc "install.sh: an incomplete copy is refused" 1 "$rc" "$out"
expect_match "install.sh: naming the missing file" "lib/notify is missing" "$out"
expect "install.sh: having installed nothing" test ! -e /usr/local/sbin/kitchen-checkup

# A running update must not have its scripts replaced under it.
systemd-run --quiet --unit=kitchen-update.service sleep 120
run_install
systemctl stop kitchen-update.service
systemctl reset-failed kitchen-update.service 2>/dev/null
expect_rc "install.sh: refused while kitchen-update.service runs" 1 "$rc" "$out"
expect_match "install.sh: and says so" "kitchen-update.service is running right now" "$out"
expect "install.sh: having installed nothing" test ! -e /usr/local/sbin/kitchen-checkup

# ---- A: the first install
run_install
show "install.sh, first run" "$out"
expect_rc "first install" 0 "$rc" "$out"
for f in "${BINS[@]}"; do
  expect_eq "/usr/local/sbin/$f: root:root 0755" "root:root 755" "$(owner_mode "/usr/local/sbin/$f")"
  expect "/usr/local/sbin/$f: the shipped file" cmp -s "$SRC/bin/$f" "/usr/local/sbin/$f"
done
expect_eq "/usr/local/lib/kitchen-sink: root:root 0755" "root:root 755" "$(owner_mode /usr/local/lib/kitchen-sink)"
for f in "${LIBS[@]}"; do
  expect_eq "lib/$f: root:root 0755" "root:root 755" "$(owner_mode "/usr/local/lib/kitchen-sink/$f")"
  expect "lib/$f: the shipped file" cmp -s "$SRC/lib/$f" "/usr/local/lib/kitchen-sink/$f"
done
for f in "${CONFIGS[@]}"; do
  expect_eq "/etc/kitchen-sink/$f: root:root 0644" "root:root 644" "$(owner_mode "/etc/kitchen-sink/$f")"
  expect "/etc/kitchen-sink/$f: the shipped file" cmp -s "$SRC/etc/kitchen-sink/$f" "/etc/kitchen-sink/$f"
done
for f in "${UNITS[@]}"; do
  expect_eq "$f: root:root 0644" "root:root 644" "$(owner_mode "/etc/systemd/system/$f")"
  expect_eq "$f: loaded" "loaded" "$(systemctl show -P LoadState "$f")"
done
expect_eq "sysusers.d: root:root 0644" "root:root 644" "$(owner_mode /etc/sysusers.d/kitchen-update.conf)"
expect_eq "tmpfiles.d: root:root 0644" "root:root 644" "$(owner_mode /etc/tmpfiles.d/kitchen-update.conf)"
expect "group kitchen-update exists" getent group kitchen-update
expect_eq "group kitchen-update has no members" "" "$(getent group kitchen-update | cut -d: -f4)"
expect "/run/kitchen-update exists" test -d /run/kitchen-update
expect_eq "systemd-escape -p /mnt/data" "mnt-data" "$(systemd-escape -p /mnt/data)"
for t in kitchen-checkup.timer btrfs-scrub@-.timer btrfs-scrub@mnt-data.timer; do
  expect_eq "$t: enabled" "enabled" "$(enabled "$t")"
  expect_eq "$t: started" "active" "$(systemctl is-active "$t")"
done
expect_eq "kitchen-update.timer: NOT enabled" "disabled" "$(enabled kitchen-update.timer)"
expect_eq "kitchen-update.timer: not started" "inactive" "$(systemctl is-active kitchen-update.timer)"
expect_match "says the updater's timer is left off" "left off +kitchen-update\.timer" "$out"
expect_match "the units pass systemd-analyze verify" "verified +the four units" "$out"
expect_nomatch "the scrub timers are the ones the check-up watches" "is not among the timers the check-up watches" "$out"
expect_match "a scrub mount that is not btrfs (here) is flagged" "WARNING +/mnt/data is not a mounted btrfs" "$out"
expect_match "counts what it changed" "^Installed: [0-9]+ change" "$out"
expect_match "prints the next steps" "sudo kitchen-update --grant-test" "$out"
expect_eq "no sudo grant was written" "" "$(find /etc/sudoers.d -name '*kitchen-update*')"
expect_eq "the shipped configs' checksums are recorded" "3" "$(grep -c . /var/lib/kitchen-sink/configs.sha256)"

# ---- B: again, with nothing to do
mtime=$(stat -c %Y /usr/local/sbin/kitchen-update)
run_install
expect_rc "second install" 0 "$rc" "$out"
expect_match "second install: nothing changed" "^Already installed: nothing changed\.$" "$out"
expect_nomatch "second install: no file touched" "^  (installed|updated|fixed mode|removed|enabled|kept) " "$out"
expect_eq "second install: files keep their mtime" "$mtime" "$(stat -c %Y /usr/local/sbin/kitchen-update)"

# ---- C: a config you changed is kept; the shipped one goes next to it
echo 'ROOT_WARN_GIB=50' >>/etc/kitchen-sink/checkup.conf
run_install
expect_rc "changed config: install" 0 "$rc" "$out"
expect_eq "changed config: yours stays" "ROOT_WARN_GIB=50" "$(tail -n 1 /etc/kitchen-sink/checkup.conf)"
expect "changed config: the shipped one is checkup.conf.new" cmp -s "$SRC/etc/kitchen-sink/checkup.conf" /etc/kitchen-sink/checkup.conf.new
expect_eq "changed config: .new is root:root 0644" "root:root 644" "$(owner_mode /etc/kitchen-sink/checkup.conf.new)"
expect_match "changed config: says how to merge" "diff -u /etc/kitchen-sink/checkup\.conf /etc/kitchen-sink/checkup\.conf\.new" "$out"
run_install
expect_match "changed config, again: .new still waits" "still waits to be merged" "$out"
expect_match "changed config, again: nothing changed" "^Already installed: nothing changed" "$out"
cp "$SRC/etc/kitchen-sink/checkup.conf" /etc/kitchen-sink/checkup.conf
run_install
expect "merged config: the .new is cleaned up" test ! -e /etc/kitchen-sink/checkup.conf.new
expect_match "merged config: and says so" "removed +/etc/kitchen-sink/checkup\.conf\.new" "$out"

# A config nobody edited, installed by an older version: it is updated in
# place, not left behind as a .new. Fake the older version and its record.
sed -i '/kitchen-update-probe/d' /etc/kitchen-sink/journal-ignore.regex
old_sum=$(sha256sum </etc/kitchen-sink/journal-ignore.regex | cut -d' ' -f1)
sed -i "s/^[0-9a-f]*  journal-ignore\.regex\$/$old_sum  journal-ignore.regex/" /var/lib/kitchen-sink/configs.sha256
run_install
expect_rc "older unedited config: install" 0 "$rc" "$out"
expect "older unedited config: updated in place" cmp -s "$SRC/etc/kitchen-sink/journal-ignore.regex" /etc/kitchen-sink/journal-ignore.regex
expect "older unedited config: no .new" test ! -e /etc/kitchen-sink/journal-ignore.regex.new
expect_match "older unedited config: says why" "updated +/etc/kitchen-sink/journal-ignore\.regex \(0644; you had not changed it\)" "$out"
expect_eq "older unedited config: the new checksum is recorded" "$(sha256sum <"$SRC/etc/kitchen-sink/journal-ignore.regex" | cut -d' ' -f1)" \
  "$(awk '$2 == "journal-ignore.regex" { print $1 }' /var/lib/kitchen-sink/configs.sha256)"

# An edited config keeps the checksum of the version it started from, so the
# next shipped change is still offered as a .new, never forced on it.
echo 'NVME_TEMP_WARN=75' >>/etc/kitchen-sink/checkup.conf
run_install
expect "edited config: .new offered" test -e /etc/kitchen-sink/checkup.conf.new
expect_eq "edited config: its record is still the shipped version's" "$(sha256sum <"$SRC/etc/kitchen-sink/checkup.conf" | cut -d' ' -f1)" \
  "$(awk '$2 == "checkup.conf" { print $1 }' /var/lib/kitchen-sink/configs.sha256)"
cp "$SRC/etc/kitchen-sink/checkup.conf" /etc/kitchen-sink/checkup.conf
run_install

# ---- D: owners and modes are put right
chown "$USER_NAME" /etc/kitchen-sink/update.conf
chmod 0666 /etc/kitchen-sink/update.conf
chmod 0700 /usr/local/sbin/kitchen-checkup
touch /usr/local/lib/kitchen-sink/old-helper
run_install
expect_rc "repair: install" 0 "$rc" "$out"
expect_eq "repair: a config others could write is root:root 0644 again" "root:root 644" "$(owner_mode /etc/kitchen-sink/update.conf)"
expect_eq "repair: a script is 0755 again" "root:root 755" "$(owner_mode /usr/local/sbin/kitchen-checkup)"
expect_match "repair: says so" "fixed mode +/etc/kitchen-sink/update\.conf" "$out"
expect "repair: a helper no longer shipped is removed" test ! -e /usr/local/lib/kitchen-sink/old-helper

# Once turned on by hand (after the supervised run), a reinstall leaves it on.
systemctl enable --quiet kitchen-update.timer
run_install
expect_rc "updater on: install" 0 "$rc" "$out"
expect_eq "updater on: kitchen-update.timer stays enabled" "enabled" "$(enabled kitchen-update.timer)"
expect_match "updater on: says so" "left on +kitchen-update\.timer" "$out"
expect_nomatch "updater on: no proving steps in Next" "--grant-test" "$out"
systemctl disable --quiet kitchen-update.timer

# ---- E: the check-up, by hand and under its unit
# No desktop here: keep the toast from waiting 3 minutes for a session.
echo 'NOTIFY_WAIT_SECS=1' >>/etc/kitchen-sink/checkup.conf
out=$(kitchen-checkup --no-notify 2>&1)
rc=$?
expect "check-up by hand: a result, not a crash (exit 1 or 2, got $rc)" test "$rc" -eq 1 -o "$rc" -eq 2
expect_eq "check-up: latest.txt points at today's report" "$TODAY.txt" "$(readlink /var/log/kitchen-checkup/latest.txt)"
expect_eq "check-up: the report is readable without sudo" "root:root 644" "$(owner_mode "/var/log/kitchen-checkup/$TODAY.txt")"
expect_eq "check-up: the report directory too" "root:root 755" "$(owner_mode /var/log/kitchen-checkup)"
expect_match "check-up: latest.json has a status" "^(OK|WARN|FAIL)$" "$(jq -r .status /var/log/kitchen-checkup/latest.json)"
expect_match "check-up: the timers check sees the updater's timer off" "not enabled: .*kitchen-update\.timer" \
  "$(jq -r '.checks[] | select(.check == "timers") | .message' /var/log/kitchen-checkup/latest.json)"

sleep 1
t0=$(date +%s)
systemctl start kitchen-checkup.service
expect_eq "check-up unit: WARN and FAIL results count as success" "success" "$(systemctl show -P Result kitchen-checkup.service)"
expect_match "check-up unit: its exit status is the result (1 or 2)" "^[12]$" "$(systemctl show -P ExecMainStatus kitchen-checkup.service)"
expect_match "check-up journal: FAIL lines at err" "^FAIL " "$(journalctl -q -u kitchen-checkup --since "@$t0" -p 3..3 -o cat)"
expect_match "check-up journal: OK lines at info" "^OK " "$(journalctl -q -u kitchen-checkup --since "@$t0" -p 6..6 -o cat)"
expect_nomatch "check-up journal: no raw <N> prefix left" "^<[0-9]>" "$(journalctl -q -u kitchen-checkup --since "@$t0" -o cat)"
expect_match "check-up journal: notify said, at notice, that no session is there" "^notify: $USER_NAME has no session bus" \
  "$(journalctl -q -u kitchen-checkup --since "@$t0" -p 5..5 -o cat)"
cp "$SRC/etc/kitchen-sink/checkup.conf" /etc/kitchen-sink/checkup.conf

# ---- F: the updater under its unit, and the check-up reading its night
sleep 1
t0=$(date +%s)
timeout 900 systemctl start kitchen-update.service
expect_eq "updater unit: a HELD night is a success" "success" "$(systemctl show -P Result kitchen-update.service)"
expect_eq "updater: status.json says HELD" "HELD" "$(jq -r .state /var/lib/kitchen-update/status.json)"
expect_match "updater: held at the session gate" "^session: no user bus" "$(jq -r '.reasons[0]' /var/lib/kitchen-update/status.json)"
expect_eq "updater: no grant was made" "none" "$(jq -r .grant /var/lib/kitchen-update/status.json)"
expect "updater: no rule left in sudoers.d" test ! -e /etc/sudoers.d/98-kitchen-update
expect_match "updater journal: the hold at warning priority" "^HOLD +session: no user bus" \
  "$(journalctl -q -u kitchen-update --since "@$t0" -p 4..4 -o cat)"
expect_nomatch "updater journal: no raw <N> prefix left" "^<[0-9]>" "$(journalctl -q -u kitchen-update --since "@$t0" -o cat)"
expect_match "updater unit: ExecStopPost ran --revoke" "revoke: no grant present" "$(journalctl -q -u kitchen-update --since "@$t0" -o cat)"
expect_eq "updater: the day log is readable for the toast's click" "root:root 644" "$(owner_mode "/var/log/kitchen-update/$TODAY.log")"
expect_eq "updater: its state directory is readable" "root:root 755" "$(owner_mode /var/lib/kitchen-update)"

kitchen-checkup --no-notify --json >/tmp/checkup.json 2>/dev/null
expect_match "check-up reads the night the updater wrote: WARN, HELD, and why" "^WARN last night: HELD: session: no user bus" \
  "$(jq -r '.checks[] | select(.check == "auto-update") | "\(.level) \(.message)"' /tmp/checkup.json)"
expect_eq "check-up: no leftover grant" "OK" "$(jq -r '.checks[] | select(.check == "grant") | .level' /tmp/checkup.json)"

# ---- F1: the unit's timeouts under kitchen-sink's 5 s stop default
# Omarchy's 10-faster-shutdown.conf; without its own TimeoutStopSec the unit
# would be SIGKILLed 5 s after a stop, before recording anything.
install -d /etc/systemd/system.conf.d
printf '[Manager]\nDefaultTimeoutStopSec=5s\n' >/etc/systemd/system.conf.d/10-faster-shutdown.conf
systemctl daemon-reexec
for _ in {1..30}; do systemctl is-system-running >/dev/null 2>&1 && break; sleep 0.5; done
expect_eq "timeouts: kitchen-sink's 5 s default is in effect here" "5s" "$(systemctl show -P TimeoutStopUSec kitchen-checkup.service)"
expect_eq "timeouts: the updater keeps its own 3 min to stop" "3min" "$(systemctl show -P TimeoutStopUSec kitchen-update.service)"
expect_eq "timeouts: and 3 h 30 min to run" "3h 30min" "$(systemctl show -P TimeoutStartUSec kitchen-update.service)"

# ---- F2: logind holds off a reboot while packages install
out=$(bash -c '
  source /usr/local/sbin/kitchen-update
  W=$(mktemp -d)
  inhibit_start
  systemd-inhibit --list --no-legend --no-pager | grep kitchen-update
  inhibit_stop
  echo "after: $(systemd-inhibit --list --no-legend --no-pager | grep -c kitchen-update)"
  rm -rf "$W"' 2>&1)
expect_match "inhibitor: taken" "^ok +run: restart and power off are held off while the update runs" "$out"
expect_match "inhibitor: shutdown, block mode, by kitchen-update" "^kitchen-update .* shutdown .*block" "$out"
expect_match "inhibitor: released after" "^after: 0$" "$out"

# ---- F3: a process that escaped the unit through the user manager
# What omarchy-restart-app (uwsm app) or systemd-run --user --scope does on
# kitchen-sink: the process moves into user@1000.service, keeps the group, and
# survives the unit. The check-up must see it, and the next slot must kill it.
uid=$(id -u "$USER_NAME")
kgid=$(getent group kitchen-update | cut -d: -f3)
systemctl start "user@$uid.service"
for _ in {1..20}; do [[ -S /run/user/$uid/bus ]] && break; sleep 0.5; done
setpriv --reuid="$USER_NAME" --regid="$USER_NAME" --groups="$(id -G "$USER_NAME" | tr ' ' ','),$kgid" -- \
  env -i PATH=/usr/bin XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
  systemd-run --user --scope --quiet --collect bash -c 'exec -a escaped-carrier sleep 600' </dev/null >/dev/null 2>&1 &
escaped=""
for _ in {1..40}; do
  escaped=$(pgrep -f '^escaped-carrier' | head -n 1)
  [[ -n $escaped ]] && break
  sleep 0.25
done
expect_match "escape: it sits in the user manager" "user@$uid\.service/" "$(cat "/proc/${escaped:-0}/cgroup" 2>&1)"
expect_match "escape: with the group" "^Groups:.*[[:space:]]$kgid([[:space:]]|$)" "$(grep ^Groups: "/proc/${escaped:-0}/status" 2>&1)"
kitchen-checkup --no-notify --json >/tmp/checkup.json 2>/dev/null
expect_match "check-up: the escaped process is a FAIL" "^FAIL 1 process outside a nightly run still carries the kitchen-update group \(gid $kgid\): $escaped sleep" \
  "$(jq -r '.checks[] | select(.check == "grant") | "\(.level) \(.message)"' /tmp/checkup.json)"
sleep 1
t0=$(date +%s)
timeout 300 systemctl start kitchen-update.service
expect "escape: the next slot killed it" test ! -e "/proc/$escaped"
expect_match "escape: and said so" "group: killed 1 process\(es\) still carrying the kitchen-update group after the update: $escaped sleep \(.*user@$uid\.service" \
  "$(journalctl -q -u kitchen-update --since "@$t0" -o cat)"
expect_match "escape: kept with the night's record" "^group: killed 1 process" "$(jq -r '.warnings[0]' /var/lib/kitchen-update/status.json)"
kitchen-checkup --no-notify --json >/tmp/checkup.json 2>/dev/null
expect_eq "check-up: the group is clear again" "OK" "$(jq -r '.checks[] | select(.check == "grant") | .level' /tmp/checkup.json)"
expect_match "check-up: the night's warning shows" "^WARN .*Look at: group: killed 1 process" \
  "$(jq -r '.checks[] | select(.check == "auto-update") | "\(.level) \(.message)"' /tmp/checkup.json)"
systemctl stop "user@$uid.service"

# ---- G: the grant test, and its sudo probes kept out of the check-up's journal count
sleep 1
t0=$(date +%s)
out=$(kitchen-update --grant-test 2>&1)
rc=$?
expect_rc "grant test with the installed files and group" 0 "$rc" "$out"
expect_match "grant test: passed" "grant test: passed" "$out"
expect "grant test: no rule left" test ! -e /etc/sudoers.d/98-kitchen-update
probes=$(journalctl -q -p err --since "@$t0" -o cat | grep -c 'kitchen-update-probe')
expect "grant test: its refused probes reach the journal at err or worse ($probes)" test "$probes" -ge 1
# The check-up's own journal check, run from the installed script and filter.
journal_check=$(bash -c '
  source /usr/local/sbin/kitchen-checkup
  OUTPUT=none STATE_DIR=$(mktemp -d)
  echo "@$1" >"$STATE_DIR/last-run"
  check_journal
  printf "%s\n" "${messages[@]}" "$details"' _ "$t0")
expect_nomatch "check-up: the probes are filtered out" "kitchen-update-probe" "$journal_check"

# ---- H: a leftover grant
printf '%%kitchen-update ALL=(ALL:ALL) NOTAFTER=%s NOPASSWD: ALL\n' "$(date -u -d '+1 hour' +%Y%m%d%H%M%SZ)" >/etc/sudoers.d/98-kitchen-update
chmod 0440 /etc/sudoers.d/98-kitchen-update
run_install
expect_match "install warns about a leftover grant" "WARNING +/etc/sudoers.d/98-kitchen-update exists" "$out"
kitchen-checkup --no-notify --json >/tmp/checkup.json 2>/dev/null
expect_eq "check-up: a leftover grant is a FAIL" "FAIL" "$(jq -r '.checks[] | select(.check == "grant") | .level' /tmp/checkup.json)"
# The revoke toasts; no desktop here to wait for.
echo 'NOTIFY_WAIT_SECS=0' >>/etc/kitchen-sink/update.conf

# ---- I: uninstall
run_uninstall
show "uninstall.sh, first run (with a leftover grant)" "$out"
expect_rc "uninstall" 0 "$rc" "$out"
expect_match "uninstall: kitchen-update --revoke found and removed the grant" "revoke +kitchen-update ended without revoking" "$out"
expect "uninstall: the grant is gone" test ! -e /etc/sudoers.d/98-kitchen-update
expect_eq "uninstall: no dotted temp rule either" "" "$(find /etc/sudoers.d -name '.kitchen-update.*')"
expect_eq "uninstall: sudo -l shows nothing of kitchen-update" "" "$(sudo -l -U "$USER_NAME" | grep -i kitchen)"
for p in "${INSTALLED[@]}"; do
  expect "uninstall: $p removed" test ! -e "$p"
done
for f in "${UNITS[@]}"; do
  expect_eq "uninstall: $f unknown to systemd" "not-found" "$(systemctl show -P LoadState "$f")"
done
expect_eq "uninstall: no enable link left" "" "$(find /etc/systemd/system -name 'kitchen-*')"
expect "uninstall: group kitchen-update removed" test -z "$(getent group kitchen-update)"
expect "uninstall: /run/kitchen-update removed" test ! -e /run/kitchen-update
expect "uninstall: the check-up's package DB cache removed" test ! -e /var/cache/kitchen-checkup
for d in /var/lib/kitchen-update /var/lib/kitchen-checkup /var/log/kitchen-update /var/log/kitchen-checkup; do
  expect "uninstall: $d kept without --purge" test -d "$d"
done
expect_eq "uninstall: the leftover grant's night is on record as FAILED" "FAILED" "$(jq -r .state /var/lib/kitchen-update/status.json)"
expect_eq "uninstall: the scrub of / stays on" "enabled" "$(enabled btrfs-scrub@-.timer)"
expect_eq "uninstall: the scrub of /mnt/data stays on" "enabled" "$(enabled btrfs-scrub@mnt-data.timer)"
expect_eq "uninstall: /etc/pacman.conf untouched, pin and all" "$pacman_conf_sum" "$(sha256sum /etc/pacman.conf)"
expect "uninstall: the pre-refresh-pacman hook stays" test -f "$hook"
expect_match "uninstall: says the pin stays" "Kept the IgnorePkg pin" "$out"
expect_match "uninstall: says the scrubs stay" "Kept the monthly scrub btrfs-scrub@-\.timer" "$out"

run_uninstall
expect_rc "uninstall again" 0 "$rc" "$out"
expect_match "uninstall again: nothing to remove" "^Nothing to remove" "$out"

run_uninstall --bogus
expect_rc "uninstall: an unknown argument is refused" 2 "$rc" "$out"

run_uninstall --purge --disable-scrubs
expect_rc "uninstall --purge --disable-scrubs" 0 "$rc" "$out"
for d in /var/lib/kitchen-update /var/lib/kitchen-checkup /var/log/kitchen-update /var/log/kitchen-checkup; do
  expect "purge: $d removed" test ! -e "$d"
done
expect_eq "disable-scrubs: the scrub of / is off" "disabled" "$(enabled btrfs-scrub@-.timer)"
expect_eq "disable-scrubs: the scrub of /mnt/data is off" "disabled" "$(enabled btrfs-scrub@mnt-data.timer)"

# ---- J: a fresh install after all that, and a clean removal
run_install
expect_rc "reinstall" 0 "$rc" "$out"
expect_eq "reinstall: the scrubs are back on" "enabled" "$(enabled btrfs-scrub@-.timer)"
expect "reinstall: the group is back" getent group kitchen-update
run_uninstall --purge
expect_rc "final uninstall --purge" 0 "$rc" "$out"
expect_eq "final: nothing of ours left in /etc/systemd/system" "" "$(find /etc/systemd/system -name 'kitchen-*')"
expect_eq "final: nothing left under /usr/local" "" "$(find /usr/local -name 'kitchen-*')"

t_summary install
