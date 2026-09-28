#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034,SC2154,SC2329,SC2001,SC2013 # variables and stubs are read by the sourced script under test; sed runs over multi-line text

# Static checks for the updater's files, in an Arch container: bash -n, Python
# byte-compilation, and systemd's own verification of the units, the timer's
# calendar, sysusers and tmpfiles. (shellcheck runs from koalaman/shellcheck in run.sh.)

set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
SRC=${SRC:-$(readlink -f "$HERE/../..")}
# shellcheck source=lib.sh
source "$HERE/lib.sh"

for f in "$SRC"/bin/kitchen-update "$SRC"/lib/{safe-to-update,preflight,postflight} "$SRC"/tests/update/*.sh; do
  out=$(bash -n "$f" 2>&1); rc=$?
  expect_rc "bash -n ${f#"$SRC"/}" 0 "$rc" "$out"
done

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
for f in lib/evwatch.py lib/news-check.py; do
  out=$(python3 -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$SRC/$f" "$work/x.pyc" 2>&1); rc=$?
  expect_rc "py_compile $f" 0 "$rc" "$out"
done

# systemd-analyze verify wants the ExecStart binaries in place.
if [[ -e /.dockerenv || ${KITCHEN_TEST_CONTAINER:-} == 1 ]]; then
  install -Dm755 "$SRC/bin/kitchen-update" /usr/local/sbin/kitchen-update
  install -Dm644 "$SRC/systemd/kitchen-update.service" /etc/systemd/system/kitchen-update.service
  install -Dm644 "$SRC/systemd/kitchen-update.timer" /etc/systemd/system/kitchen-update.timer
  out=$(systemd-analyze verify --man=no /etc/systemd/system/kitchen-update.service /etc/systemd/system/kitchen-update.timer 2>&1); rc=$?
  expect_rc "systemd-analyze verify: service and timer" 0 "$rc" "$out"
  expect_eq "systemd-analyze verify: no complaints" "" "$out"
fi
cal=$(sed -n 's/^OnCalendar=//p' "$SRC/systemd/kitchen-update.timer")
out=$(systemd-analyze calendar --iterations=5 "$cal" 2>&1); rc=$?
expect_rc "timer: OnCalendar parses" 0 "$rc" "$out"
expect_eq "timer: the four slots, then the next night" "02:30:00 03:30:00 04:30:00 05:30:00 02:30:00" \
  "$(grep -oE '(Next elapse|Iteration #[0-9]+): .* ([0-9:]{8}) ' <<<"$out" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | paste -sd' ' -)"
expect_match "timer: no catch-up at boot" "^Persistent=false$" "$(cat "$SRC/systemd/kitchen-update.timer")"
expect_match "timer: randomized by 10 min" "^RandomizedDelaySec=10min$" "$(cat "$SRC/systemd/kitchen-update.timer")"
expect_match "service: ExecStopPost revokes" "^ExecStopPost=/usr/local/sbin/kitchen-update --revoke$" "$(cat "$SRC/systemd/kitchen-update.service")"
expect_nomatch "service: no PrivateTmp/ProtectSystem/ProtectHome" "^(PrivateTmp|ProtectSystem|ProtectHome)=" "$(cat "$SRC/systemd/kitchen-update.service")"

# The unit's start timeout must cover the run's own limits, or a slow night
# (the update's timeout, then the postflight waiting for pacman) is killed
# after S6 with nothing recorded. Allowances for what has no single setting:
# S1 15 min, S2's passes 2 min, S3 15 min, S7's Secure Boot status 3 min.
secs() { systemd-analyze timespan "$1" 2>/dev/null | awk '$1 == "μs:" || $1 == "us:" { printf "%d", $2 / 1000000 }'; }
conf() { sed -nE "s/^$1=//p" "$SRC/etc/kitchen-sink/update.conf"; }
unit=$(cat "$SRC/systemd/kitchen-update.service")
start_limit=$(secs "$(sed -n 's/^TimeoutStartSec=//p' <<<"$unit")")
budget=$(( $(conf QUIET_SECS) + $(secs "$(conf UPDATE_TIMEOUT)") + $(secs "$(conf UPDATE_KILL_AFTER)") + $(conf PACMAN_WAIT_SECS) \
  + $(conf WATCHER_WAIT_SECS) + $(conf NOTIFY_WAIT_SECS) + (15 + 2 + 15 + 3) * 60 ))
expect "service: TimeoutStartSec ($start_limit s) covers the run's own limits ($budget s)" test "${start_limit:-0}" -ge "$budget"
# Its stop timeout must outlast the run's exit (a critical toast waits up to
# NOTIFY_WAIT_SECS) and the stop hook; kitchen-sink's DefaultTimeoutStopSec is 5 s.
stop_limit=$(secs "$(sed -n 's/^TimeoutStopSec=//p' <<<"$unit")")
expect "service: TimeoutStopSec is set, and covers a toast's wait (${stop_limit:-unset} s)" test "${stop_limit:-0}" -ge $(( $(conf NOTIFY_WAIT_SECS) + 60 ))

out=$(systemd-sysusers --dry-run "$SRC/etc/sysusers.d/kitchen-update.conf" 2>&1); rc=$?
expect_rc "sysusers: parses" 0 "$rc" "$out"
out=$(systemd-tmpfiles --dry-run --create "$SRC/etc/tmpfiles.d/kitchen-update.conf" 2>&1); rc=$?
expect_rc "tmpfiles: parses" 0 "$rc" "$out"

# The config is sourced by root: it must be plain assignments and comments.
expect_eq "update.conf: only comments and KEY=VALUE lines" "" \
  "$(grep -vE '^(#.*|[A-Z_][A-Z0-9_]*=.*|)$' "$SRC/etc/kitchen-sink/update.conf")"
out=$(bash -n "$SRC/etc/kitchen-sink/update.conf" 2>&1); rc=$?
expect_rc "update.conf: bash -n" 0 "$rc" "$out"
# Every key in the config has the same default in the scripts that read it.
for key in $(sed -nE 's/^([A-Z_][A-Z0-9_]*)=.*/\1/p' "$SRC/etc/kitchen-sink/update.conf"); do
  conf_value=$(sed -nE "s/^$key=//p" "$SRC/etc/kitchen-sink/update.conf")
  users=$(grep -lE "^$key=" "$SRC/bin/kitchen-update" "$SRC"/lib/{safe-to-update,preflight,postflight})
  if [[ -z $users ]]; then
    t_fail "update.conf: $key has no built-in default"
    continue
  fi
  mismatch=""
  for f in $users; do
    [[ $(sed -nE "s/^$key=//p" "$f") == "$conf_value" ]] || mismatch+="${f##*/} "
  done
  expect_eq "update.conf: $key matches the built-in default" "" "$mismatch"
done

t_summary lint
