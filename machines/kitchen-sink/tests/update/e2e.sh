#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034,SC2154,SC2329,SC2001,SC2013 # variables and stubs are read by the sourced script under test; sed runs over multi-line text

# kitchen-update end to end, as root in a throwaway Arch container
# (tests/update/run.sh starts one). The orchestrator, the grant, safe-to-update
# and postflight are the real ones. Faked: the desktop session (a bus socket,
# a process named Hyprland, the user manager's Environment), the Omarchy
# commands, checkupdates, the preflight (it needs the mirrors) and notify.
#
# The fake omarchy-update records what it was given (environment, groups,
# stdin, tty), proves sudo works inside its own process tree, and appends a
# real pacman.log excerpt through sudo, like pacman would.

set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
SRC=${SRC:-$(readlink -f "$HERE/../..")}
FX=$HERE/fixtures
# shellcheck source=lib.sh
source "$HERE/lib.sh"

if [[ ! -e /.dockerenv && ${KITCHEN_TEST_CONTAINER:-} != 1 ]]; then
  echo "e2e.sh fakes a desktop and writes sudoers: run it in a container (tests/update/run.sh)" >&2
  exit 2
fi

pacman -Sy --noconfirm --needed sudo jq python >/dev/null 2>&1 || { echo "pacman -S failed"; exit 1; }

# ---- the machine
id desk >/dev/null 2>&1 || useradd -m -G wheel desk
echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel
uid=$(id -u desk)
install -Dm755 "$SRC/bin/kitchen-update" /usr/local/sbin/kitchen-update
install -Dm644 "$SRC/etc/sysusers.d/kitchen-update.conf" /etc/sysusers.d/kitchen-update.conf
install -Dm644 "$SRC/etc/tmpfiles.d/kitchen-update.conf" /etc/tmpfiles.d/kitchen-update.conf
systemd-sysusers /etc/sysusers.d/kitchen-update.conf >/dev/null
systemd-tmpfiles --create /etc/tmpfiles.d/kitchen-update.conf
kgid=$(getent group kitchen-update | cut -d: -f3)
mkdir -p /boot /opt/state /opt/fixtures
cp "$FX"/pacman-*.log /opt/fixtures/
chmod -R a+rX /opt/fixtures
install -d -m 1777 /tmp/fake

# The session: a user bus socket, a Hyprland instance dir, a process called Hyprland.
install -d -o desk -g desk -m 0700 "/run/user/$uid" "/run/user/$uid/hypr" "/run/user/$uid/hypr/abc_123"
runuser -u desk -- python3 -c "import socket; socket.socket(socket.AF_UNIX).bind('/run/user/$uid/bus')"
cp /usr/bin/sleep /usr/local/bin/Hyprland
runuser -u desk -- /usr/local/bin/Hyprland 3600 &

# The libraries: the real ones, with a stub preflight and notify.
LIB=/opt/testlib
install -d "$LIB"
install -m755 "$SRC/lib/safe-to-update" "$SRC/lib/postflight" "$LIB/"
install -m644 "$SRC/lib/evwatch.py" "$SRC/lib/news-check.py" "$LIB/"
cat >"$LIB/preflight" <<'EOF'
#!/bin/bash
# Stub preflight: the verdict comes from /opt/state/preflight-mode.
W=${!#}
printf '%s\n' automake frei0r-plugins imagemagick ldb libwbclient owe owe-lockfeed qpdf smbclient ttfx >"$W/targets.txt"
: >"$W/failed-units.before"
date -Iseconds >"$W/news-checked-at"
case $(cat /opt/state/preflight-mode 2>/dev/null || echo care) in
  care) echo "CARE  boot-chain: boot chain: limine limine-mkinitcpio-hook; 6 files that rebuild the UKI"; echo "VERDICT GO-WITH-CARE"; exit 10 ;;
  hold) echo "HOLD  news: Arch news since yesterday needs a human first: Mkinitcpio >=42 requires manual intervention"; echo "VERDICT HOLD"; exit 20 ;;
  retry) echo "RETRY network: unreachable: https://mirror.omarchy.org/core/os/x86_64/core.db"; echo "VERDICT RETRY"; exit 40 ;;
  nothing) echo "ok    pending: nothing to update"; echo "VERDICT NOTHING-TO-DO"; exit 30 ;;
esac
EOF
cat >"$LIB/notify" <<'EOF'
#!/bin/bash
printf '%q ' "$@" >>/tmp/fake/notify.txt
echo >>/tmp/fake/notify.txt
echo "notify: toast sent (stub)" >&2
EOF
chmod 755 "$LIB/preflight" "$LIB/notify"

# Omarchy, faked: the tripwire needles, migrations, the user manager's Environment.
FAKE=/opt/fakeomarchy
install -d "$FAKE/bin"
cat >"$FAKE/bin/omarchy-update" <<'EOF'
#!/bin/bash
# Fake omarchy-update. The lines kitchen-update's tripwire looks for:
# if [[ -z ${OMARCHY_UPDATE_LOGGED:-} ]]; then
# [[ ${1:-} != "-y" ]] || export OMARCHY_UPDATE_UNATTENDED=1
#     echo -e "\e[33mContinuing the update without a snapshot.\e[0m" >&2
env | sort >/tmp/fake/env.txt
id -G >/tmp/fake/groups.txt
readlink /proc/$$/fd/0 >/tmp/fake/stdin.txt
for fd in /proc/$$/fd/*; do readlink "$fd"; done >/tmp/fake/fds.txt
if [[ -t 0 || -t 1 ]]; then echo tty >/tmp/fake/tty.txt; fi
echo "$*" >/tmp/fake/args.txt
touch /tmp/fake/update-ran
echo -e "\e[32m\nUpdate system packages\e[0m"
if sudo -n /usr/bin/true; then echo "fake: sudo -n works inside the update"; else echo "fake: sudo -n REFUSED inside the update"; exit 1; fi
sudo -n tee -a /var/log/pacman.log <"/opt/fixtures/$(cat /opt/state/pacman-fixture 2>/dev/null || echo pacman-upgrade-with-uki.log)" >/dev/null
case $(cat /opt/state/update-mode 2>/dev/null || echo ok) in
  fail)
    echo -e "\033[0;31mSomething went wrong during the update!\033[0m"
    exit 1
    ;;
  timeout)
    trap 'echo "fake: TERM arrived, trap ran after the phase"; touch /tmp/fake/trap; exit 143' TERM
    # Stands in for pacman: it must never be signalled.
    bash -c 'sleep 8; touch /tmp/fake/phase-done'
    echo "fake: phase finished"
    ;;
  daemon)
    # A hook that leaves a background process holding the output open.
    sleep 45 &
    ;;
  escape)
    # What `uwsm app` or `systemd-run --user --scope` does on kitchen-sink: a
    # process that outlives the run, still carrying the group.
    setsid bash -c 'exec -a escaped-carrier sleep 300' </dev/null >/dev/null 2>&1 &
    echo $! >/tmp/fake/escaped.pid
    ;;
  nosnap)
    echo -e "\e[33mNo Snapper configs found, so no snapshot was created.\e[0m" >&2
    echo -e "\e[33mContinuing the update without a snapshot.\e[0m" >&2
    ;;
  aur)
    # Omarchy's AUR phase: its header, then yay asking sudo for a build that
    # appeared after the preflight (yay spends seconds on the AUR first).
    echo -e "\e[32m\nUpdate AUR packages\e[0m"
    sleep 1
    if sudo -n /usr/bin/true 2>/dev/null; then echo "fake: AUR build got sudo"; else echo "fake: AUR build refused sudo"; exit 1; fi
    ;;
  slow)
    touch /tmp/fake/slow-started
    sleep 120
    ;;
esac
echo "Linux kernel has been updated. Reboot? Run omarchy-system-reboot when ready."
exit 0
EOF
cat >"$FAKE/bin/omarchy-update-aur-pkgs" <<'EOF'
#!/bin/bash
    echo -e "\e[32m\nUpdate AUR packages\e[0m"
EOF
cat >"$FAKE/bin/omarchy-update-orphan-pkgs" <<'EOF'
#!/bin/bash
if [[ ! -t 0 || ! -t 1 ]]; then
  exit 0
fi
EOF
cat >"$FAKE/bin/omarchy-update-restart" <<'EOF'
#!/bin/bash
  if [[ ${OMARCHY_UPDATE_UNATTENDED:-0} == "1" ]]; then
    echo "Run omarchy-system-reboot when ready."
  fi
EOF
cat >"$FAKE/bin/omarchy-migrate" <<'EOF'
#!/bin/bash
[[ -s /opt/state/migrations ]] || exit 1
cat /opt/state/migrations
EOF
cat >"$FAKE/bin/busctl" <<EOF
#!/bin/bash
# The user manager's Environment, shaped like kitchen-sink's (EDITOR and GUM_* must not cross).
cat <<'JSON'
{"type":"as","data":["HOME=/home/desk","LANG=en_US.UTF-8","LOGNAME=desk","PATH=$FAKE/bin:/home/desk/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/bin","SHELL=/usr/bin/bash","USER=desk","XDG_RUNTIME_DIR=/run/user/$uid","DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus","EDITOR=omarchy-launch-editor --inline","GUM_CONFIRM_PROMPT_FOREGROUND=#c0703f","HYPRLAND_INSTANCE_SIGNATURE=abc_123","OMARCHY_PATH=/usr/share/omarchy","WAYLAND_DISPLAY=wayland-1","XDG_CURRENT_DESKTOP=Hyprland","XDG_SESSION_TYPE=wayland","CUDA_PATH=/opt/cuda"]}
JSON
EOF
chmod 755 "$FAKE"/bin/*
cat >/usr/local/bin/checkupdates <<'EOF'
#!/bin/bash
rc=$(cat /opt/state/checkupdates-rc 2>/dev/null || echo 0)
(( rc == 0 )) && cat /opt/fixtures/checkupdates.txt
exit "$rc"
EOF
chmod 755 /usr/local/bin/checkupdates
grep -v '^omarchy' "$FX/checkupdates-2026-09-28.txt" >/opt/fixtures/checkupdates.txt

install -Dm644 "$SRC/etc/kitchen-sink/update.conf" /etc/kitchen-sink/update.conf
cat >>/etc/kitchen-sink/update.conf <<EOF

# ---- test overrides
DESKTOP_USER=desk
LIB_DIR=$LIB
OMARCHY_BIN=$FAKE/bin
OMARCHY_ROOT=$FAKE
NOTIFY_WAIT_SECS=0
UPDATE_TIMEOUT=60s
UPDATE_KILL_AFTER=5s
LAST_SLOT=23:59
EOF
chmod 0644 /etc/kitchen-sink/update.conf

NIGHT=$(date +%F)
STATUS=/var/lib/kitchen-update/status.json
DAYLOG=/var/log/kitchen-update/$NIGHT.log
BOOTREC=/var/lib/kitchen-update/boot-check
reset_run() {
  pkill -KILL -f escaped-carrier 2>/dev/null
  rm -f /tmp/fake/* /opt/state/*
  rm -f "$STATUS" /var/lib/kitchen-update/last-success "$BOOTREC" /var/lib/pacman/db.lck
}
# Every process that carries the kitchen-update group (none should, between runs).
carriers() {
  local f
  for f in $(grep -l -E "^Groups:.*[[:space:]]$kgid([[:space:]]|$)" /proc/[0-9]*/status 2>/dev/null); do
    grep -q '^State:[[:space:]]*Z' "$f" 2>/dev/null || echo "$f"
  done | cut -d/ -f3 | paste -sd' ' -
}
gone() { [[ ! -e /proc/$1 ]] || grep -q '^State:[[:space:]]*Z' "/proc/$1/status" 2>/dev/null; }
st() { jq -r "$1" "$STATUS" 2>/dev/null; }
run_ku() { out=$(kitchen-update "$@" 2>&1); rc=$?; }

# ---- A: a supervised night that goes all the way
reset_run
touch /run/kitchen-update/force-idle
run_ku
expect_rc "DONE: exit 0" 0 "$rc" "$out"
expect_eq "DONE: status" "DONE" "$(st .state)"
expect_eq "DONE: settled" "true" "$(st .settled)"
expect_eq "DONE: the 10 upgraded packages recorded" "10" "$(st '.upgraded | length')"
expect_eq "DONE: reboot recommended (the UKI was rebuilt)" "recommended" "$(st .reboot)"
expect_eq "DONE: grant revoked" "revoked" "$(st .grant)"
expect_match "DONE: the CARE note kept" "limine" "$(st '.care[0]')"
expect_nomatch "DONE: the reasons are postflight warnings, not the package count" "packages updated" "$(st '.reasons[]')"
expect_eq "DONE: every reason is a postflight WARN line" \
  "$(sed -n '/^==   S7 postflight/,/^==   S8 reboot check/p' <<<"$out" | grep -c '^WARN ')" "$(st '.reasons | length')"
expect "DONE: force-idle consumed" test ! -e /run/kitchen-update/force-idle
expect_match "DONE: activity skipped once" "S2 activity: skipped once \(force-idle\)" "$out"
expect "DONE: last-success written" test -s /var/lib/kitchen-update/last-success
expect_eq "DONE: no grant left" "" "$(find /etc/sudoers.d -name '98-kitchen-update' -o -name '.kitchen-update.*')"
expect_match "DONE: sudo worked inside the update's tree" "^fake: sudo -n works inside the update" "$(cat "$DAYLOG")"
expect_eq "DONE: /tmp/omarchy-update.log belongs to the user" "desk" "$(stat -c %U /tmp/omarchy-update.log)"
expect_match "DONE: and holds the update's output" "fake: sudo -n works inside the update" "$(cat /tmp/omarchy-update.log)"
expect_match "DONE: the day log has the state" "STATE DONE" "$(cat "$DAYLOG")"
expect_match "DONE: the day log is free of escapes" "^Update system packages$" "$(cat "$DAYLOG")"
expect_eq "DONE: omarchy-update got -y" "-y" "$(cat /tmp/fake/args.txt)"
expect_eq "DONE: stdin is /dev/null" "/dev/null" "$(cat /tmp/fake/stdin.txt)"
expect "DONE: no terminal" test ! -e /tmp/fake/tty.txt
expect_match "DONE: the update's tree carries the group" "(^| )$kgid( |$)" "$(cat /tmp/fake/groups.txt)"
expect_nomatch "DONE: desk's own processes don't" "(^| )$kgid( |$)" "$(runuser -u desk -- id -G)"
envs=$(cat /tmp/fake/env.txt)
expect_match "env: OMARCHY_UPDATE_LOGGED=1" "^OMARCHY_UPDATE_LOGGED=1$" "$envs"
expect_match "env: the session's Hyprland signature" "^HYPRLAND_INSTANCE_SIGNATURE=abc_123$" "$envs"
expect_match "env: the user manager's PATH" "^PATH=$FAKE/bin:/home/desk/.local/share/mise/shims:" "$envs"
expect_match "env: OMARCHY_PATH pinned to the packaged root" "^OMARCHY_PATH=$FAKE$" "$envs"
expect_match "env: runtime dir from the uid" "^XDG_RUNTIME_DIR=/run/user/$uid$" "$envs"
expect_nomatch "env: EDITOR, GUM_* and CUDA_PATH stay out" "^(EDITOR|GUM_|CUDA_PATH|JOURNAL_STREAM|SUDO_)" "$envs"
extra=$(sed 's/=.*//' <<<"$envs" | grep -vxE 'HOME|USER|LOGNAME|SHELL|LANG|PATH|WAYLAND_DISPLAY|HYPRLAND_INSTANCE_SIGNATURE|XDG_CURRENT_DESKTOP|XDG_SESSION_TYPE|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|OMARCHY_PATH|OMARCHY_UPDATE_LOGGED|PWD|SHLVL|_' | paste -sd' ' -)
expect_eq "env: nothing beyond the whitelist (and bash's own)" "" "$extra"
expect_match "toast: a normal one for DONE" "--urgency normal --title kitchen-sink\\\\ updated\\\\ overnight" "$(cat /tmp/fake/notify.txt)"
expect_match "toast: opens the day log" "--open $DAYLOG" "$(cat /tmp/fake/notify.txt)"
expect_match "toast: says a reboot is recommended" "Reboot\\\\ recommended" "$(cat /tmp/fake/notify.txt)"
expect_match "toast: a low one when the update starts, so a return mid-run sees it" "--urgency low --title Nightly\\\\ update\\\\ running" "$(cat /tmp/fake/notify.txt)"
expect_eq "history: RUNNING, then the night's result" "RUNNING DONE" "$(jq -r .state /var/lib/kitchen-update/history.jsonl | tail -n 2 | paste -sd' ' -)"
expect_nomatch "the update does not inherit the slot lock" "kitchen-update\\.lock" "$(cat /tmp/fake/fds.txt)"
expect_eq "nothing carries the group after the run" "" "$(carriers)"
expect_match "no logind here: the run says it has no shutdown inhibitor" "^WARN +run: no shutdown inhibitor" "$out"
expect "no boot-check record after a clean night" test ! -e "$BOOTREC"

# ---- B: the next slot finds the night settled
rm -f /tmp/fake/update-ran
run_ku
expect_rc "settled: exit 0" 0 "$rc" "$out"
expect_match "settled: says so" "tonight is already settled \(DONE at" "$out"
expect "settled: the update did not run again" test ! -e /tmp/fake/update-ran

# ---- C: omarchy-update fails, the boot chain is fine
reset_run
echo fail >/opt/state/update-mode
touch /run/kitchen-update/force-idle
run_ku
expect_rc "FAILED: exit 1" 1 "$rc" "$out"
expect_eq "FAILED: status" "FAILED" "$(st .state)"
expect_match "FAILED: the reason" "Something went wrong during the update" "$(st '.reasons | join(" ")')"
expect_match "FAILED: critical toast" "--urgency critical --title Nightly\\\\ update\\\\ FAILED --body" "$(cat /tmp/fake/notify.txt)"
expect_nomatch "FAILED: no DO NOT REBOOT when the boot checks passed" "DO\\\\ NOT\\\\ REBOOT" "$(cat /tmp/fake/notify.txt)"
expect "FAILED: no last-success" test ! -e /var/lib/kitchen-update/last-success
expect_eq "FAILED: grant revoked anyway" "" "$(find /etc/sudoers.d -name '98-kitchen-update')"

# ---- D: the UKI was left unsigned: DO NOT REBOOT
reset_run
echo pacman-sbctl-not-signing.log >/opt/state/pacman-fixture
touch /run/kitchen-update/force-idle
run_ku
expect_rc "unsigned UKI: exit 1" 1 "$rc" "$out"
expect_match "unsigned UKI: DO NOT REBOOT" "--title Nightly\\\\ update\\\\ FAILED\\\\ -\\\\ DO\\\\ NOT\\\\ REBOOT" "$(cat /tmp/fake/notify.txt)"
expect_match "unsigned UKI: sbctl's own words in the reasons" "not signing!" "$(st '.reasons | join(" ")')"
expect_match "unsigned UKI: the remedy, not 'until secureboot status is clean'" "^do NOT reboot: rebuild and sign the UKI with sudo limine-mkinitcpio" "$(st .action)"
# (printf %q quotes a body with non-ASCII as $'...', spaces unescaped)
expect_match "unsigned UKI: the toast says what to do at the machine" "At.{1,2}the.{1,2}machine:.{1,2}rebuild.{1,2}and.{1,2}sign.{1,2}the.{1,2}UKI" "$(cat /tmp/fake/notify.txt)"
expect "unsigned UKI: a boot-check record is kept" test -s "$BOOTREC"
expect_match "unsigned UKI: with the failing checks" "not signing!" "$(jq -r '.reasons | join(" ")' "$BOOTREC")"
expect_eq "unsigned UKI: status.json carries it" "$(jq -r .night "$BOOTREC")" "$(st .boot_check.night)"

# The next night has nothing to install. The record must not be forgotten:
# while the boot checks still fail (here: pacman died and left its lock), the
# night is HELD, not UP-TO-DATE.
rm -f /tmp/fake/* /opt/state/* /var/lib/kitchen-update/last-success
echo 2 >/opt/state/checkupdates-rc
touch /var/lib/pacman/db.lck
touch /run/kitchen-update/force-idle
run_ku
expect_eq "record stands: HELD, not UP-TO-DATE" "HELD" "$(st .state)"
expect_match "record stands: why, do NOT reboot, and the remedy for what fails now" "boot-check: the boot chain has failed its checks since .* and still does \\(pacman: .*\\)\\. do NOT reboot: finish pacman's work first" "$(st '.reasons | join(" ")')"
expect_match "record stands: its reasons are what fails now" "^pacman: " "$(jq -r '.reasons[0]' "$BOOTREC")"
expect_eq "record stands: the night it first failed is kept" "$(st .boot_check.night)" "$(jq -r .night "$BOOTREC")"
expect "record stands: kept" test -s "$BOOTREC"
out=$(kitchen-update --boot-check 2>&1); rc=$?
expect_rc "--boot-check: fails while the checks fail" 1 "$rc" "$out"
expect_match "--boot-check: says what to do" "FAIL +boot checks: FAILED; the record from .* stays.*At the machine: finish pacman's work first" "$out"
rm -f /var/lib/pacman/db.lck
out=$(kitchen-update --boot-check 2>&1); rc=$?
expect_rc "--boot-check: passes once fixed" 0 "$rc" "$out"
expect_match "--boot-check: and clears the record" "boot checks: passed; the record from .* is cleared" "$out"
expect "--boot-check: record gone" test ! -e "$BOOTREC"
# A record the checks now pass is cleared by the next slot on its own.
echo '{"night": "2026-09-27", "since": "2026-09-27T03:50:00-04:00", "reasons": ["uki: x"], "action": "y"}' >"$BOOTREC"
rm -f "$STATUS"
touch /run/kitchen-update/force-idle
run_ku
expect_eq "passing record: the night goes on (UP-TO-DATE)" "UP-TO-DATE" "$(st .state)"
expect_match "passing record: cleared, and said so" "boot-check: the boot chain that failed its checks on 2026-09-27 passes them now; record cleared" "$out"
expect "passing record: gone" test ! -e "$BOOTREC"

# ---- E: the update times out: TERM reaches omarchy-update only, after its phase
reset_run
sed -i 's/^UPDATE_TIMEOUT=.*/UPDATE_TIMEOUT=3s/; s/^UPDATE_KILL_AFTER=.*/UPDATE_KILL_AFTER=30s/' /etc/kitchen-sink/update.conf
echo timeout >/opt/state/update-mode
touch /run/kitchen-update/force-idle
run_ku
expect_rc "timeout: exit 1" 1 "$rc" "$out"
expect "timeout: the phase (pacman's stand-in) was never signalled and finished" test -e /tmp/fake/phase-done
expect "timeout: omarchy-update's TERM trap ran" test -e /tmp/fake/trap
expect_match "timeout: in that order" "fake: TERM arrived, trap ran after the phase" "$(cat "$DAYLOG")"
expect_match "timeout: reported" "omarchy-update timed out \(exit 124\)" "$(st '.reasons | join(" ")')"
expect_eq "timeout: grant revoked" "" "$(find /etc/sudoers.d -name '98-kitchen-update')"
sed -i 's/^UPDATE_TIMEOUT=.*/UPDATE_TIMEOUT=60s/; s/^UPDATE_KILL_AFTER=.*/UPDATE_KILL_AFTER=5s/' /etc/kitchen-sink/update.conf

# ---- E2: something the update started escapes the unit: S6 kills it
reset_run
echo escape >/opt/state/update-mode
touch /run/kitchen-update/force-idle
run_ku
escaped=$(cat /tmp/fake/escaped.pid 2>/dev/null)
expect_eq "escape: the night is still DONE" "DONE" "$(st .state)"
expect "escape: the escaped process is dead" gone "${escaped:-0}"
expect_eq "escape: nothing carries the group" "" "$(carriers)"
expect_match "escape: a warning names it" "^group: killed 1 process\\(es\\) still carrying the kitchen-update group after the update: [0-9]+ sleep \\(" "$(st '.warnings[0]')"
expect_match "escape: the DONE toast says to look" "Look\\\\ at:\\\\ group:" "$(cat /tmp/fake/notify.txt)"

# ---- E3: an AUR update that appeared after the preflight gets no sudo
reset_run
echo aur >/opt/state/update-mode
touch /run/kitchen-update/force-idle
run_ku
expect_rc "aur: exit 1" 1 "$rc" "$out"
expect_match "aur: the grant went when the AUR phase began" "NOTE +aur: Omarchy's AUR phase is starting; the sudo grant is removed now" "$out"
expect_match "aur: the build was refused sudo" "^fake: AUR build refused sudo" "$(cat "$DAYLOG")"
expect_nomatch "aur: never granted" "AUR build got sudo" "$(cat "$DAYLOG")"
expect_eq "aur: FAILED" "FAILED" "$(st .state)"
expect_match "aur: the reason says why" "^aur: an AUR update came up after the preflight" "$(st '.reasons[0]')"
expect_match "aur: S6 still proves the grant gone" "revoke: .* already gone; with the group, sudo -n is refused again" "$out"

# ---- E4: omarchy update went on without its snapshot
reset_run
echo nosnap >/opt/state/update-mode
touch /run/kitchen-update/force-idle
run_ku
expect_eq "no snapshot: still DONE" "DONE" "$(st .state)"
expect_match "no snapshot: a warning" "^snapshot: omarchy update ran WITHOUT a pre-update snapshot" "$(st '.warnings[0]')"
expect_nomatch "no snapshot: not among the ordinary reasons" "snapshot:" "$(st '.reasons | join(" ")')"
expect_match "no snapshot: the toast says so" "Look\\\\ at:\\\\ snapshot:" "$(cat /tmp/fake/notify.txt)"

# ---- E5: a stop in the middle of the update (systemctl stop, the unit's timeout)
reset_run
echo slow >/opt/state/update-mode
touch /run/kitchen-update/force-idle
kitchen-update >/tmp/ku.out 2>&1 &
ku=$!
for _ in {1..150}; do
  [[ -e /tmp/fake/slow-started ]] && break
  sleep 0.2
done
start=$(date +%s)
kill -TERM "$ku"
wait "$ku"
rc=$?
out=$(cat /tmp/ku.out)
expect_rc "stopped mid-update: exit 1" 1 "$rc" "$out"
expect "stopped mid-update: the trap ran at once, not after the update" test $(( $(date +%s) - start )) -lt 20
expect_eq "stopped mid-update: FAILED" "FAILED" "$(st .state)"
expect_match "stopped mid-update: why" "kitchen-update stopped \\(exit 143\\) after the update had started" "$(st '.reasons | join(" ")')"
expect "stopped mid-update: a boot-check record" test -s "$BOOTREC"
expect_match "stopped mid-update: a critical toast" "--urgency critical --title Nightly\\\\ update\\\\ interrupted" "$(cat /tmp/fake/notify.txt)"
expect_eq "stopped mid-update: the grant is gone" "" "$(find /etc/sudoers.d -name '98-kitchen-update')"
expect_eq "stopped mid-update: nothing carries the group" "" "$(carriers)"

# ---- E6: the stop hook after a run that was killed past S5 (no grant left, S6 had run)
reset_run
jq -n --arg n "$NIGHT" --arg l "$DAYLOG" '{night: $n, state: "RUNNING", settled: false, time: "2026-09-28T03:41:00-04:00", log: $l, pending: ["glibc a -> b"], pacman_from: "1"}' >"$STATUS"
run_ku --revoke
expect_rc "stop hook, RUNNING left: exit 0" 0 "$rc" "$out"
expect_eq "stop hook, RUNNING left: FAILED although no grant was found" "FAILED" "$(st .state)"
expect_match "stop hook, RUNNING left: why" "stopped or killed after the update had started \\(the update started at 2026-09-28T03:41:00-04:00\\)" "$(st '.reasons | join(" ")')"
expect_eq "stop hook, RUNNING left: the pending list kept" "glibc a -> b" "$(st '.pending[0]')"
expect_match "stop hook, RUNNING left: a critical toast" "--urgency critical --title Nightly\\\\ update\\\\ interrupted" "$(cat /tmp/fake/notify.txt)"
expect "stop hook, RUNNING left: a boot-check record" test -s "$BOOTREC"

# ---- E7: the next slot finds a RUNNING nobody finished (a power cut)
reset_run
jq -n --arg n "$(date -d yesterday +%F)" '{night: $n, state: "RUNNING", settled: false, time: "2026-09-27T03:41:00-04:00", log: "/var/log/kitchen-update/old.log"}' >"$STATUS"
printf '%%kitchen-update ALL=(ALL:ALL) NOTAFTER=%s NOPASSWD: ALL\n' "$(date -u -d '+1 hour' +%Y%m%d%H%M%SZ)" >/etc/sudoers.d/98-kitchen-update
chmod 0440 /etc/sudoers.d/98-kitchen-update
echo 2 >/opt/state/checkupdates-rc
run_ku
expect_match "power cut: the old night is recorded as FAILED" "\"state\":\"FAILED\".*a crash or a power cut" "$(grep "\"night\":\"$(date -d yesterday +%F)\"" /var/lib/kitchen-update/history.jsonl | tail -n 1)"
expect_match "power cut: a leftover grant is removed at entry" "entry: a sudo grant was left behind" "$out"
expect_eq "power cut: tonight goes on (the boot checks pass here)" "UP-TO-DATE" "$(st .state)"
expect_match "power cut: the record the old night left was re-checked and cleared" "boot-check: .* passes them now; record cleared" "$out"
expect_eq "power cut: the grant is gone" "" "$(find /etc/sudoers.d -name '98-kitchen-update')"

# ---- F: pending migrations hold the night before any grant
reset_run
echo 1790000000.sh >/opt/state/migrations
touch /run/kitchen-update/force-idle
run_ku
expect_rc "HELD (migrations): exit 0" 0 "$rc" "$out"
expect_eq "HELD (migrations): status" "HELD" "$(st .state)"
expect_match "HELD (migrations): reason" "migrations: 1 pending \(1790000000.sh\)" "$(st '.reasons | join(" ")')"
expect "HELD (migrations): the update never ran" test ! -e /tmp/fake/update-ran
expect_nomatch "HELD (migrations): no grant was written" "S4 grant" "$out"

# ---- G: nothing pending: omarchy update is never called
reset_run
echo 2 >/opt/state/checkupdates-rc
run_ku
expect_eq "UP-TO-DATE: status" "UP-TO-DATE" "$(st .state)"
expect "UP-TO-DATE: omarchy update not called (it would snapshot anyway)" test ! -e /tmp/fake/update-ran

# ---- H/I: busy slots, then the last one: BUSY, then DEFERRED, counted once per night
# The real safe-to-update runs here; the container has no logind, audio or input devices, so it is busy.
reset_run
jq -n --arg n "$(date -d yesterday +%F)" '{night: $n, state: "BUSY", nights_without_update: 2, counted_night: $n}' >"$STATUS"
run_ku
expect_rc "BUSY: exit 0" 0 "$rc" "$out"
expect_eq "BUSY: status" "BUSY" "$(st .state)"
expect_eq "BUSY: not settled" "false" "$(st .settled)"
expect_match "BUSY: the reasons are the activity check's" "inhibitors: cannot ask logind" "$(st '.reasons | join(" ")')"
expect_nomatch "BUSY: a real run stops before the 10-minute input watch" "input:" "$(st '.reasons | join(" ")')"
expect_eq "BUSY: a third night without an update" "3" "$(st .nights_without_update)"
expect "BUSY: the update did not run" test ! -e /tmp/fake/update-ran
sed -i 's/^LAST_SLOT=.*/LAST_SLOT=00:00/' /etc/kitchen-sink/update.conf
run_ku
expect_eq "DEFERRED: the last slot ends the night" "DEFERRED" "$(st .state)"
expect_eq "DEFERRED: the same night is not counted twice" "3" "$(st .nights_without_update)"
sed -i 's/^LAST_SLOT=.*/LAST_SLOT=23:59/' /etc/kitchen-sink/update.conf

# ---- J: preflight verdicts
reset_run
echo hold >/opt/state/preflight-mode
touch /run/kitchen-update/force-idle
run_ku
expect_eq "preflight HOLD: HELD" "HELD" "$(st .state)"
expect_match "preflight HOLD: its reason" "Mkinitcpio >=42" "$(st '.reasons | join(" ")')"
expect "preflight HOLD: no update" test ! -e /tmp/fake/update-ran
reset_run
echo retry >/opt/state/preflight-mode
touch /run/kitchen-update/force-idle
run_ku
expect_eq "preflight RETRY: BUSY" "BUSY" "$(st .state)"

# ---- K: a grant that can't be made safely holds the night
reset_run
gpasswd -a desk kitchen-update >/dev/null
touch /run/kitchen-update/force-idle
run_ku
gpasswd -d desk kitchen-update >/dev/null
expect_eq "grant refused: HELD" "HELD" "$(st .state)"
expect_match "grant refused: why" "grant: the sudo grant could not be created or failed its self-test: group kitchen-update has members" "$(st '.reasons | join(" ")')"
expect "grant refused: no update" test ! -e /tmp/fake/update-ran
expect_eq "grant refused: nothing left in sudoers.d" "" "$(find /etc/sudoers.d -name '98-kitchen-update' -o -name '.kitchen-update.*')"

# ---- L: a background process keeps the output open: the night still ends
reset_run
echo daemon >/opt/state/update-mode
touch /run/kitchen-update/force-idle
start=$(date +%s)
# Not $(...): that would wait for the lingering process too, which systemd never does.
kitchen-update >/tmp/ku.out 2>&1
out=$(cat /tmp/ku.out)
expect_eq "background holder: DONE anyway" "DONE" "$(st .state)"
expect "background holder: the night ends after the 30 s drain wait, not the 45 s holder" test $(( $(date +%s) - start )) -lt 44
expect_match "background holder: says so" "still holds its output open" "$out"

# ---- M: the dry run prints every gate and the exact command, and writes nothing
reset_run
before=$(sha256sum <"$DAYLOG")
# With no state directory, as on a fresh install: a dry run reads it only if it exists.
mv /var/lib/kitchen-update /var/lib/kitchen-update.aside
run_ku --dry-run --quiet-secs 1
state_dir_created=$([[ -e /var/lib/kitchen-update ]] && echo yes || echo no)
rm -rf /var/lib/kitchen-update
mv /var/lib/kitchen-update.aside /var/lib/kitchen-update
expect_rc "dry run: exit 0" 0 "$rc" "$out"
for stage in "S0 entry" "S1 static gates" "S2 activity" "S3 compatibility" "S4 grant" "S5 would run" "DRY RUN VERDICT: BUSY \(the next slot tries again\)"; do
  expect_match "dry run: prints $stage" "$stage" "$out"
done
expect_eq "dry run: the state directory is not created" "no" "$state_dir_created"
expect_match "dry run: every activity check, even after the first busy one" "pass 2: instant checks again" "$out"
expect_match "dry run: the input watch ran anyway" "input: the input watch failed" "$out"
expect_match "dry run: the rule it would write" "info +grant: +%kitchen-update ALL=\(ALL:ALL\) NOTAFTER=[0-9]{14}Z NOPASSWD: ALL" "$out"
expect_match "dry run: the environment, one per line" "info +  HYPRLAND_INSTANCE_SIGNATURE=abc_123" "$out"
expect_match "dry run: the command, exactly as it would run" "info +  timeout --foreground -k 5s 60s setpriv --reuid=$uid --regid=$(id -g desk) --groups=[0-9,]+,$kgid -- env -i HOME=/home/desk .* OMARCHY_UPDATE_LOGGED=1 /bin/bash -c 'exec > >\\(exec tee /tmp/omarchy-update.log\\) 2>&1; exec $FAKE/bin/omarchy-update -y </dev/null'\$" "$out"
expect "dry run: no status written" test ! -e "$STATUS"
expect_eq "dry run: the day log untouched" "$before" "$(sha256sum <"$DAYLOG")"
expect "dry run: the update did not run" test ! -e /tmp/fake/update-ran
expect_eq "dry run: no grant" "" "$(find /etc/sudoers.d -name '98-kitchen-update')"
# In the daytime a dry run is past the last slot: DEFERRED, which is busy too.
sed -i 's/^LAST_SLOT=.*/LAST_SLOT=00:00/' /etc/kitchen-sink/update.conf
run_ku --dry-run --quiet-secs 1
sed -i 's/^LAST_SLOT=.*/LAST_SLOT=23:59/' /etc/kitchen-sink/update.conf
expect_match "dry run after the last slot: DEFERRED, saying it is busy" "DRY RUN VERDICT: DEFERRED \(busy, and no slot is left tonight" "$out"
expect "dry run after the last slot: no status written" test ! -e "$STATUS"

# ---- M2: ExecStopPost finds the grant still there: the run was killed mid-update
reset_run
printf '%%kitchen-update ALL=(ALL:ALL) NOTAFTER=%s NOPASSWD: ALL\n' "$(date -u -d '+1 hour' +%Y%m%d%H%M%SZ)" >/etc/sudoers.d/98-kitchen-update
chmod 0440 /etc/sudoers.d/98-kitchen-update
run_ku --revoke
expect_rc "ExecStopPost: exit 0 once the grant is gone" 0 "$rc" "$out"
expect_eq "ExecStopPost: the grant is gone" "" "$(find /etc/sudoers.d -name '98-kitchen-update')"
expect_eq "ExecStopPost: the night is recorded as FAILED" "FAILED" "$(st .state)"
expect_match "ExecStopPost: and why" "ended without revoking its sudo grant" "$(st '.reasons | join(" ")')"
expect_match "ExecStopPost: a critical toast" "--urgency critical --title Nightly\\\\ update\\\\ interrupted" "$(cat /tmp/fake/notify.txt)"
expect "ExecStopPost: the boot chain is re-checked before the next night trusts it" test -s "$BOOTREC"
run_ku --revoke
expect_eq "ExecStopPost after a normal run: nothing recorded" "" "$(grep -c . /tmp/fake/notify.txt | grep -v '^1$')"

# ---- N: usage
run_ku --quiet-secs 5
expect_rc "usage: --quiet-secs only with --dry-run" 2 "$rc" "$out"
run_ku --bogus
expect_rc "usage: unknown flag" 2 "$rc" "$out"

kill %1 2>/dev/null
t_summary e2e
