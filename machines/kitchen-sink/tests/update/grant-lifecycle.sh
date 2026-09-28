#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034,SC2154,SC2329,SC2001,SC2013 # variables and stubs are read by the sourced script under test; sed runs over multi-line text

# The nightly sudo grant's whole life, with the real sudo, as root in a
# throwaway Arch container (tests/update/run.sh starts one). Never run this on
# a real machine: it creates users and writes /etc/sudoers.d.
#
# "desk" plays kevinwyckoff: in wheel, with `%wheel ALL=(ALL:ALL) ALL`, so
# sudo normally wants a password. "other" is a second account.

set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
SRC=${SRC:-$(readlink -f "$HERE/../..")}
# shellcheck source=lib.sh
source "$HERE/lib.sh"

if [[ ! -e /.dockerenv && ${KITCHEN_TEST_CONTAINER:-} != 1 ]]; then
  echo "grant-lifecycle.sh changes users and sudoers: run it in a container (tests/update/run.sh)" >&2
  exit 2
fi

# ---- a machine to test on
pacman -Sy --noconfirm --needed sudo jq >/dev/null 2>&1 || { echo "pacman -S sudo failed"; exit 1; }
echo "---- $(sudo -V | head -n 1), $(setpriv --version)"
install -Dm755 "$SRC/bin/kitchen-update" /usr/local/sbin/kitchen-update
install -d /usr/local/lib/kitchen-sink
install -Dm644 "$SRC/etc/sysusers.d/kitchen-update.conf" /etc/sysusers.d/kitchen-update.conf
install -Dm644 "$SRC/etc/tmpfiles.d/kitchen-update.conf" /etc/tmpfiles.d/kitchen-update.conf
install -Dm644 "$SRC/etc/kitchen-sink/update.conf" /etc/kitchen-sink/update.conf
sed -i 's/^DESKTOP_USER=.*/DESKTOP_USER=desk/; s/^NOTIFY=.*/NOTIFY=0/' /etc/kitchen-sink/update.conf
id desk >/dev/null 2>&1 || useradd -m -G wheel desk
id other >/dev/null 2>&1 || useradd -m other
echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel
grep -q '^@includedir /etc/sudoers.d' /etc/sudoers || echo '@includedir /etc/sudoers.d' >>/etc/sudoers
GRANT=/etc/sudoers.d/98-kitchen-update

# ---- sysusers and tmpfiles
systemd-sysusers /etc/sysusers.d/kitchen-update.conf
entry=$(getent group kitchen-update)
expect_match "sysusers: the group exists" "^kitchen-update:x:[0-9]+:$" "$entry"
kg=$(cut -d: -f3 <<<"$entry")
expect "sysusers: a system gid (below 1000)" test "$kg" -lt 1000
expect_match "sysusers: no group password, so newgrp can't join" "^kitchen-update:(!|!\*|\*)?:" "$(getent gshadow kitchen-update)"
systemd-tmpfiles --create /etc/tmpfiles.d/kitchen-update.conf
expect_eq "tmpfiles: /run/kitchen-update for the force-idle flag" "755 root" "$(stat -c '%a %U' /run/kitchen-update 2>&1)"

# ---- the grant test the design runs on kitchen-sink (T5)
out=$(kitchen-update --grant-test 2>&1); rc=$?
expect_rc "--grant-test: passes" 0 "$rc" "$out"
expect_match "--grant-test: rule in place, visudo ok" "^ok +grant: $GRANT in place for %kitchen-update \(gid $kg\), NOTAFTER [0-9]{14}Z UTC, visudo ok" "$out"
expect_match "--grant-test: with the group sudo -n works" "^ok +grant: with the kitchen-update group, desk's sudo -n works" "$out"
expect_match "--grant-test: without it sudo -n is refused" "^ok +grant: without the group, desk's sudo -n is refused" "$out"
expect_match "--grant-test: a grandchild after sudo -k" "^ok +grant: a grandchild of the grouped process gets sudo -n too, after sudo -k" "$out"
expect_match "--grant-test: newgrp is refused" "^ok +grant: newgrp kitchen-update is refused for desk" "$out"
expect_match "--grant-test: sudo -l -U unchanged during" "^ok +grant: sudo -l -U desk is unchanged while the rule is in place" "$out"
expect_match "--grant-test: revoked and proven" "^ok +revoke: $GRANT removed; with the group, sudo -n is refused again" "$out"
expect_match "--grant-test: sudo -l -U same as before" "^ok +grant: sudo -l -U desk is the same as before the test" "$out"
expect "--grant-test: no rule left" test ! -e "$GRANT"
echo "$out" | sed 's/^/        > /'

# ---- the pieces, step by step
# shellcheck source=/dev/null
source /usr/local/sbin/kitchen-update
load_conf
load_user
kgid=$(group_gid)
as_desk_grouped() { setpriv --reuid=desk --regid=desk --groups="$(id -G desk | tr ' ' ','),$kgid" -- env -i PATH=/usr/bin "$@"; }

out=$(grant_create 10 2>&1); rc=$?
expect_rc "grant_create: writes the rule" 0 "$rc" "$out"
expect_eq "grant file: 0440 root:root" "440 root root" "$(stat -c '%a %U %G' "$GRANT")"
expect_match "grant file: the designed rule" "^%kitchen-update ALL=\(ALL:ALL\) NOTAFTER=[0-9]{14}Z NOPASSWD: ALL$" "$(cat "$GRANT")"
expect "grant file: the whole sudoers config parses" visudo -cq
expect "desk WITH the group: sudo -n works" probe_with_group
expect_eq "desk WITH the group: sudo -n id -u is root" "0" "$(as_desk_grouped /usr/bin/sudo -n -N /usr/bin/id -u 2>&1)"
if probe_without_group; then t_fail "desk WITHOUT the group (runuser): refused"; else t_ok "desk WITHOUT the group (runuser): refused"; fi
if su desk -c '/usr/bin/sudo -n -N /usr/bin/true' >/dev/null 2>&1; then t_fail "desk's own login shell (su): refused"; else t_ok "desk's own login shell (su): refused"; fi
if setpriv --reuid=other --regid=other --init-groups -- /usr/bin/sudo -n -N /usr/bin/true >/dev/null 2>&1; then
  t_fail "other WITHOUT the group: refused"
else
  t_ok "other WITHOUT the group: refused"
fi
expect "other WITH the group (only root can add it): works, the gid is the key" \
  setpriv --reuid=other --regid=other --groups="$(id -G other | tr ' ' ','),$kgid" -- /usr/bin/sudo -n -N /usr/bin/true
expect_eq "sudo -N left no timestamp behind for desk" "" "$(ls /run/sudo/ts/desk 2>/dev/null)"

# A dotted file is ignored by sudo's includedir, which is why the rule is staged under one.
echo 'desk ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/.kitchen-update.leftover
chmod 0440 /etc/sudoers.d/.kitchen-update.leftover
if probe_without_group; then t_fail "a dotted file in sudoers.d is ignored"; else t_ok "a dotted file in sudoers.d is ignored"; fi

out=$(grant_revoke 2>&1); rc=$?
expect_rc "grant_revoke: succeeds" 0 "$rc" "$out"
expect "grant_revoke: rule gone" test ! -e "$GRANT"
expect "grant_revoke: a crash's temp file gone too" test ! -e /etc/sudoers.d/.kitchen-update.leftover
if probe_with_group; then t_fail "after revoke, WITH the group: refused"; else t_ok "after revoke, WITH the group: refused"; fi

# ---- NOTAFTER: the rule expires by itself
install -m 0440 /dev/null "$GRANT"
expires=$(( $(date +%s) + 5 ))
grant_rule "$(date -u -d "@$expires" +%Y%m%d%H%M%SZ)" >"$GRANT"
expect "NOTAFTER +5s: parses" visudo -cq
expect "NOTAFTER +5s: works now" probe_with_group
# Wait on the clock, not a fixed sleep: WSL2 steps its VM clock now and then.
for _ in {1..60}; do
  (( $(date +%s) > expires + 1 )) && break
  sleep 0.5
done
if probe_with_group; then t_fail "NOTAFTER +5s: refused once it has passed, with the file still there"; else t_ok "NOTAFTER +5s: refused once it has passed, with the file still there"; fi
grant_rule "$(date -u -d '-1 min' +%Y%m%d%H%M%SZ)" >"$GRANT"
if probe_with_group; then t_fail "NOTAFTER in the past: refused"; else t_ok "NOTAFTER in the past: refused"; fi
rm -f "$GRANT"

# ---- kitchen-update --revoke, as ExecStopPost runs it
grant_create 10 >/dev/null 2>&1
out=$(kitchen-update --revoke 2>&1); rc=$?
expect_rc "--revoke: removes a live grant" 0 "$rc" "$out"
expect_match "--revoke: and proves it" "^ok +revoke: $GRANT removed; with the group, sudo -n is refused again" "$out"
out=$(kitchen-update --revoke 2>&1); rc=$?
expect_rc "--revoke: nothing to do is fine" 0 "$rc" "$out"
expect_match "--revoke: says so, without probing" "^info +revoke: no grant present" "$out"

# ---- tmpfiles: a grant that outlived its run goes at boot, and only then
grant_create 10 >/dev/null 2>&1
touch /etc/sudoers.d/.kitchen-update.crash
systemd-tmpfiles --create --remove /etc/tmpfiles.d/kitchen-update.conf
expect "tmpfiles without --boot: the rule stays (r! is boot-only)" test -e "$GRANT"
systemd-tmpfiles --boot --remove /etc/tmpfiles.d/kitchen-update.conf
expect "tmpfiles --boot: the rule is removed" test ! -e "$GRANT"
expect "tmpfiles --boot: the crash's temp file too" test ! -e /etc/sudoers.d/.kitchen-update.crash
grant_live=0

# ---- a process that still carries the group is part of the grant
# On kitchen-sink such a process is one the update started through the user
# manager (uwsm app, systemd-run --user --scope), which moves it out of the
# unit's cgroup; here it is simply a process outside the updater.
setpriv --reuid=desk --regid=desk --groups="$(id -G desk | tr ' ' ','),$kgid" -- sleep 300 &
carrier=$!
for _ in {1..50}; do
  gid_carriers | grep -q "^$carrier " && break
  sleep 0.1
done
expect_match "carriers: the scan finds it, with its uid and name" "^$carrier $(id -u desk) [^ ]* sleep$" "$(gid_carriers)"
expect_eq "carriers: nothing else carries the group" "1" "$(gid_carriers | grep -c .)"
out=$(grant_create 10 2>&1); rc=$?
expect_rc "carriers: the grant is refused while one lives" 1 "$rc" "$out"
expect_match "carriers: and names it" "^FAIL +grant: 1 process\(es\) already carry the kitchen-update group, and the rule would give them root: $carrier sleep" "$out"
expect "carriers: no rule written" test ! -e "$GRANT"
out=$(kitchen-update --grant-test 2>&1); rc=$?
expect_rc "carriers: --grant-test fails too" 1 "$rc" "$out"
expect "carriers: still no rule" test ! -e "$GRANT"
out=$(kitchen-update --revoke 2>&1); rc=$?
expect_rc "carriers: --revoke succeeds" 0 "$rc" "$out"
expect_match "carriers: --revoke kills it, and says so" "^WARN +group: killed 1 process\(es\) still carrying the kitchen-update group after the update: $carrier sleep" "$out"
wait "$carrier" 2>/dev/null
expect "carriers: it is gone" test ! -e "/proc/$carrier"
expect_eq "carriers: none left" "" "$(gid_carriers)"
out=$(grant_create 10 2>&1); rc=$?
expect_rc "carriers: with none left, the grant is written again" 0 "$rc" "$out"
grant_revoke >/dev/null 2>&1

# ---- refusals: never write a rule the group or sudoers would make unsafe
gpasswd -a other kitchen-update >/dev/null
out=$(grant_create 10 2>&1); rc=$?
expect_rc "a member in the group: refused" 1 "$rc" "$out"
expect_match "a member in the group: says why" "^FAIL +grant: group kitchen-update has members" "$out"
expect "a member in the group: no rule written" test ! -e "$GRANT"
gpasswd -d other kitchen-update >/dev/null

useradd -M -N -g kitchen-update sneaky
out=$(grant_create 10 2>&1); rc=$?
expect_rc "the group as someone's primary group: refused" 1 "$rc" "$out"
userdel sneaky

grant_rule() { echo 'this is not a sudoers line'; }
out=$(grant_create 10 2>&1); rc=$?
expect_rc "visudo rejects the rule: refused" 1 "$rc" "$out"
expect "visudo rejects the rule: nothing written" test ! -e "$GRANT"
expect_eq "visudo rejects the rule: no temp file left" "" "$(find /etc/sudoers.d -name '.kitchen-update.*')"
unset -f grant_rule
# shellcheck source=/dev/null
source /usr/local/sbin/kitchen-update
load_conf
load_user
grant_live=0

groupdel kitchen-update
out=$(grant_create 10 2>&1); rc=$?
expect_rc "no group: refused" 1 "$rc" "$out"
expect_match "no group: says how to fix it" "systemd-sysusers" "$out"
out=$(kitchen-update --revoke 2>&1); rc=$?
expect_rc "no group: --revoke still works" 0 "$rc" "$out"
systemd-sysusers /etc/sysusers.d/kitchen-update.conf

t_summary grant-lifecycle
