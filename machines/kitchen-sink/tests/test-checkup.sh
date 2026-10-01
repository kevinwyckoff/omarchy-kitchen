#!/bin/bash

# Tests for bin/kitchen-checkup: its parsing and thresholds, fed with fixtures.
#
# It sources the script (the source guard keeps main from running), replaces
# every command a check calls with a function that answers from tests/fixtures,
# runs one check at a time and compares the level and message it recorded.
# The fixtures are real output from kitchen-sink and from btrfs-progs 7.1,
# except the kitchen-update status files, which follow the design's fields, and
# the thermal daemon's state.json and journal entries (fixtures/thermal), which
# follow lib/kitchen-thermald.py's state() (version 1) and its KITCHEN_* journal
# fields. nvme-probe.json is kitchen-sink's real X0 probe, serials replaced.

# The stubs read STUB_* variables through indirect expansion, and the settings
# test re-sources the script in a subshell for its pristine defaults.
# shellcheck disable=SC2034,SC2031

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
F=$here/fixtures
# shellcheck source=tests/lib.sh
source "$here/lib.sh"
# shellcheck source=bin/kitchen-checkup
source "$here/../bin/kitchen-checkup"

# Local dates matter (the updater's nights start at 02:00 local); pin them to
# kitchen-sink's zone, spelled out so no tzdata is needed.
export TZ=EST5EDT,M3.2.0,M11.1.0 LC_ALL=C

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
OUTPUT=none

# ---- stubs --------------------------------------------------------------------

run_timeout() {
  shift
  "$@"
}
user_uid() { echo 1000; }
user_home() { echo "$T/home"; }
user_session() { return "$STUB_SESSION"; }
as_user() { printf '%s' "$STUB_USER_FAILED"; }
boot_epoch() { echo "$STUB_BOOT"; }
boot_id() { echo "$STUB_BOOT_ID"; }
pacman_running() { return "$STUB_PACMAN_RUNNING"; }
hyprland_exes() { printf '%s\n' "$STUB_HYPR_EXE"; }
uptime() { echo "up 20 hours, 42 minutes"; }
update_gid() { echo "$STUB_GID"; }
gid_carriers() { [[ $1 == "$STUB_GID" ]] && printf '%s' "$STUB_CARRIERS"; }
uki_uname() { [[ -f $1 ]] && [[ -n $STUB_UKI_UNAME ]] && echo "$STUB_UKI_UNAME"; }
nvidia_dkms_pkg() { echo "$STUB_NVIDIA"; }
dkms_module_built() { [[ " $STUB_DKMS_BUILT " == *" $1 "* ]]; }
nct_module_file() { [[ -n $STUB_NCT_FILE ]] && echo "$STUB_NCT_FILE"; }
thermal_pkg() { [[ -n $STUB_THERMAL_PKG ]] && echo "$STUB_THERMAL_PKG"; }
nvme_probe() { cat "$T/nvme-probe.json"; }
thermal_journal() { cat "$STUB_THERMAL_JOURNAL"; }
hook_journal() { printf '%s' "$STUB_HOOK_JOURNAL"; }

uname() {
  case $1 in
  -r) echo "$STUB_KERNEL" ;;
  -n) echo kitchen-sink ;;
  *) command uname "$@" ;;
  esac
}

checkupdates() {
  [[ -n $STUB_CHECKUPDATES ]] && cat "$STUB_CHECKUPDATES"
  return "$STUB_CHECKUPDATES_RC"
}

pacman() {
  case $1 in
  -Q)
    [[ -n $STUB_OMARCHY_DEV ]] || return 1
    echo "omarchy-dev $STUB_OMARCHY_DEV"
    ;;
  -Qqo)
    if [[ $2 == "$SB_ENGINE" ]]; then
      [[ -n $STUB_ENGINE_OWNER ]] || return 1
      echo "$STUB_ENGINE_OWNER"
    elif [[ $2 == */vmlinuz && " $STUB_VMLINUZ_OWNED " == *" $(basename "$(dirname "$2")") "* ]]; then
      echo linux-omarchy
    else
      return 1
    fi
    ;;
  -Qu) [[ -n $STUB_QU ]] && cat "$STUB_QU" ;;
  *) echo "unexpected pacman $*" >&2 && return 99 ;;
  esac
}

pacman-conf() {
  # shellcheck disable=SC2086 # one package per line, like pacman-conf
  [[ $1 == "IgnorePkg" ]] && printf '%s\n' $STUB_IGNOREPKG
}

systemctl() {
  local unit=${*: -1}
  case $* in
  "list-units --failed --plain --no-legend --full") cat "$STUB_FAILED" ;;
  "is-active --quiet "*) [[ " $STUB_INACTIVE " != *" $unit "* ]] ;;
  "is-enabled "*)
    local state=enabled pair
    for pair in $STUB_TIMER_STATES; do
      [[ ${pair%%=*} == "$unit" ]] && state=${pair#*=}
    done
    echo "$state"
    [[ $state == "enabled" ]]
    ;;
  "show -P ActiveState $THERMAL_UNIT") echo "$STUB_THERMAL_ACTIVE" ;;
  "show -P ActiveState "*) echo "$STUB_UPDATE_STATE" ;;
  "show -P LoadState $THERMAL_UNIT") echo "$STUB_THERMAL_LOAD" ;;
  "show -P MainPID $THERMAL_UNIT") echo "$STUB_THERMAL_PID" ;;
  *) echo "unexpected systemctl $*" >&2 && return 99 ;;
  esac
}

btrfs() {
  local fs=${*: -1} key
  key=$( [[ $fs == "/" ]] && echo root || echo data)
  case "$1 $2" in
  "filesystem usage") cat "$STUB_USAGE" ;;
  "device stats")
    local file=STUB_STATS_$key
    cat "${!file}"
    ! grep -q ' [1-9][0-9]*$' "${!file}"
    ;;
  "scrub status")
    local file=STUB_SCRUB_$key
    cat "${!file}"
    ;;
  *) echo "unexpected btrfs $*" >&2 && return 99 ;;
  esac
}

df() {
  case "$*" in
  *"--output=avail /boot") printf '    Avail\n%s\n' "$STUB_BOOT_FREE" ;;
  *"--output=avail /") printf '    Avail\n%s\n' "$STUB_ROOT_DF" ;;
  *"--output=pcent"*) printf 'Use%%\n %s%%\n' "$STUB_DATA_PCT" ;;
  esac
}

mountpoint() { [[ " $STUB_MOUNTED " == *" ${*: -1} "* ]]; }

findmnt() {
  case $2 in
  SOURCE) [[ -n $STUB_DATA_SRC ]] && echo "$STUB_DATA_SRC" ;;
  OPTIONS) [[ -n $STUB_DATA_SRC ]] && echo "$STUB_DATA_OPTS" ;;
  esac
}

timedatectl() { echo "$STUB_NTP"; }
journalctl() { cat "$STUB_JOURNAL"; }
pacdiff() { printf '%s' "$STUB_PACNEW"; }

coredumpctl() {
  if [[ -n $STUB_CORES ]]; then
    cat "$STUB_CORES"
  else
    echo "No coredumps found." >&2
    return 1
  fi
}

# A Secure Boot engine that answers status with the real verbose output and the
# exit status in $T/sb-rc.
cat >"$T/omarchy-secureboot" <<EOF
#!/bin/bash
[[ \$1 == "status" ]] || exit 9
[[ \${2:-} == "--quiet" ]] || cat "$F/sb-status-verbose.txt"
exit \$(cat "$T/sb-rc")
EOF
chmod +x "$T/omarchy-secureboot"

# An NVMe helper that prints $T/nvme-now.json.
printf 'import sys\nsys.stdout.write(open("%s").read())\n' "$T/nvme-now.json" >"$T/nvme-stub.py"

# A healthy kitchen-sink on 2026-09-28 at 09:03, with the pin in place, and
# the thermal events running: the patched nct6775 loaded, every source sending
# events, and the system drive (the only case A drive, by X0) armed with its
# threshold lowered to its 70C level.
reset() {
  levels=() checks=() messages=() details=""
  pending="" pending_rc=1 pending_count=-1 held_back=""
  us_present=0 us_state="" us_night="" us_reasons="" us_hint="" us_reboot="" us_log="" us_packages="" us_nights="" us_reboot_why="" us_epoch=0
  arm_loaded=0 arm_pairs="" nvme_probe_json="" nvme_json=""
  rm -rf "${T:?}/home" "$T/state" "$T/cache" "$T/log" "${T:?}/etc" "$T/modules" "$T/nct6775_core"
  mkdir -p "$T/home/${PIN_HOOK%/*}" "$T/state" "$T/cache" "$T/etc" "$T/modules/7.2.5-4-omarchy" "$T/boot" "$T/nct6775_core/parameters"
  touch "$T/home/$PIN_HOOK" "$T/modules/7.2.5-4-omarchy/vmlinuz" "$T/boot/omarchy_linux-omarchy.efi"
  echo linux-omarchy >"$T/modules/7.2.5-4-omarchy/pkgbase"
  printf '\x06\x00\x00\x00\x01' >"$T/efivar"
  echo 0 >"$T/sb-rc"
  cp "$F/nvme-health.json" "$T/nvme-now.json"
  echo 1000 >"$T/nct6775_core/parameters/notify_interval"
  cp "$F/thermal/state-event.json" "$T/thermal-state.json"
  mkdir -p "$T/doc"
  printf '# version: 7.2.5\n# checked-through: 7.2.8\n' >"$T/doc/upstream.sha256"
  printf '# the daemon'"'"'s settings\nNVME_ARM=system\n' >"$T/thermal.conf"
  jq '.SYSDRIVE0001 |= (.armed = true | .aen_config.current = 514 | .aen_config.current_hex = "0x00000202"
    | .temp_over.current_k = 343 | .temp_over.current_c = 70)' "$F/nvme-probe.json" >"$T/nvme-probe.json"
  NVME_SERIALS="SYSDRIVE0001:system DATADRIVE0001:data"
  THERMAL_STATE=$T/thermal-state.json THERMAL_CONF=$T/thermal.conf NCT_SYSFS=$T/nct6775_core THERMAL_DKMS_DOC=$T/doc
  STUB_THERMAL_LOAD=loaded STUB_THERMAL_ACTIVE=active STUB_THERMAL_PID=1234 STUB_THERMAL_PKG="nct6775-notify-dkms 7.2.5.1-1"
  STUB_NCT_FILE=/lib/modules/7.2.5-4-omarchy/updates/dkms/nct6775-core.ko.zst
  STUB_THERMAL_JOURNAL=$F/thermal/journal-day.json STUB_HOOK_JOURNAL=""

  now=$(date -d '2026-09-28T09:03:00-04:00' +%s)
  REPORT_DIR=$T/log STATE_DIR=$T/state CACHE_DIR=$T/cache
  SB_ENGINE=$T/omarchy-secureboot EFI_SECUREBOOT_VAR=$T/efivar
  NVME_HELPER=$T/nvme-stub.py JOURNAL_IGNORE=$here/../etc/kitchen-sink/journal-ignore.regex
  PACMAN_LOG=$F/pacman/pacman.log PACMAN_LOCK=$T/db.lck MODULES_DIR=$T/modules
  UPDATE_STATUS=$T/status.json UPDATE_LAST_SUCCESS=$T/last-success UPDATE_GRANT=$T/etc/98-kitchen-update
  UPDATE_REBOOT_PENDING=$T/reboot-pending UPDATE_BOOT_CHECK=$T/boot-check
  UKI_PATTERN=$T/boot/omarchy_%s.efi
  NOTIFY_CMD=$T/notify-stub
  rm -f "$T/status.json" "$T/last-success" "$T/db.lck" "$T/reboot-pending" "$T/boot-check"

  STUB_SESSION=0 STUB_USER_FAILED="" STUB_BOOT=$(date -d '2026-09-27T11:09:17-04:00' +%s)
  STUB_BOOT_ID=5f0c6a2e-8c1d-4c55-9a55-0b1f3e2d7a10
  STUB_PACMAN_RUNNING=1 STUB_HYPR_EXE=/usr/bin/Hyprland STUB_KERNEL=7.2.5-4-omarchy
  STUB_CHECKUPDATES=$F/pacman/checkupdates.txt STUB_CHECKUPDATES_RC=0 STUB_QU=$F/pacman/qu-ignored.txt
  STUB_OMARCHY_DEV=4.0.0.r6647.gcca0894-1 STUB_ENGINE_OWNER=omarchy-dev STUB_VMLINUZ_OWNED=7.2.5-4-omarchy
  STUB_IGNOREPKG="omarchy-dev omarchy-settings-dev"
  STUB_FAILED=$F/failed-units.txt STUB_INACTIVE="" STUB_UPDATE_STATE=inactive
  STUB_TIMER_STATES="kitchen-update.timer=enabled"
  STUB_USAGE=$F/btrfs/usage-root.txt STUB_ROOT_DF=445647986688
  STUB_STATS_root=$F/btrfs/stats-clean.txt STUB_STATS_data=$F/btrfs/stats-clean.txt
  STUB_SCRUB_root=$F/btrfs/scrub-finished.txt STUB_SCRUB_data=$F/btrfs/scrub-finished.txt
  STUB_BOOT_FREE=1289748480 STUB_DATA_PCT=1 STUB_MOUNTED="/ /mnt/data"
  STUB_DATA_SRC=/dev/mapper/omarchy_data STUB_DATA_OPTS=rw,noatime,compress=zstd:1,ssd,discard=async,space_cache=v2,subvolid=5,subvol=/
  STUB_NTP=yes STUB_JOURNAL=/dev/null STUB_PACNEW="" STUB_CORES=""
  STUB_GID=969 STUB_CARRIERS="" STUB_UKI_UNAME=7.2.5-4-omarchy STUB_NVIDIA=nvidia-open-dkms STUB_DKMS_BUILT=7.2.5-4-omarchy
  sb_state=unknown boot_problem="" boot_verified=0
}

status_file() { # fixture [age-in-hours [jq-filter]]: install an updater status.json written that long before now
  jq "${3:-.}" "$F/kitchen-update/$1" >"$T/status.json" 2>/dev/null || cp "$F/kitchen-update/$1" "$T/status.json"
  touch -d "@$((now - ${2:-5} * 3600))" "$T/status.json"
}

# ---- Secure Boot --------------------------------------------------------------

reset
check_secureboot
expect "sb clean" secureboot OK "status clean" "SecureBoot=1"
expect_eq "sb clean state" "$sb_state" clean

reset
echo 1 >"$T/sb-rc"
check_secureboot
expect "sb failing" secureboot FAIL "needs attention" "Do not reboot"
expect_has "sb failing detail" "$details" "Omarchy Secure Boot - Status"
expect_eq "sb failing state" "$sb_state" failing

reset
SB_ENGINE=$T/no-such-engine
check_secureboot
expect "sb engine missing" secureboot FAIL "engine is missing" "Do not reboot"

reset
rm "$T/efivar"
check_secureboot
expect "sb no efivar" secureboot OK "SecureBoot=unknown"

# ---- pin ----------------------------------------------------------------------

reset
collect_updates
check_pin
expect "pin held back" pin INFO "held back by IgnorePkg" "omarchy-dev 4.0.0.r6663.g3faafba-1" "omarchy-settings-dev 4.0.0.r6663.g3faafba-4"
expect_eq "pin ok first" "${levels[0]} ${checks[0]}" "OK pin"
expect_none "pin hook present" pin-hook

reset
STUB_QU=""
collect_updates
check_pin
expect "pin ok, nothing held" pin OK "IgnorePkg holds omarchy-dev omarchy-settings-dev" "4.0.0.r6647"

reset
STUB_IGNOREPKG="omarchy-dev"
check_pin
expect "pin half missing" pin FAIL "lacks omarchy-settings-dev" "Secure Boot engine"

reset
STUB_IGNOREPKG=""
printf '%s\n' "omarchy-dev 4.0.0.r6647.gcca0894-1 -> 4.0.0.r6663.g3faafba-1" >"$T/cu-offered"
STUB_CHECKUPDATES=$T/cu-offered STUB_QU=""
collect_updates
check_pin
expect "pin missing, repo offers" pin FAIL "lacks omarchy-dev omarchy-settings-dev" "the repo offers omarchy-dev 4.0.0.r6663.g3faafba-1"

reset
STUB_ENGINE_OWNER=""
check_pin
expect "not the kitchen build" pin INFO "not the kitchen build"

reset
STUB_OMARCHY_DEV=""
check_pin
expect "no omarchy-dev" pin INFO "not installed"

reset
rm "$T/home/$PIN_HOOK"
check_pin
expect "pin hook missing" pin-hook WARN "10-kitchen-pin is missing"

# ---- leftover grant -----------------------------------------------------------

reset
check_grant
expect "no grant" grant OK

reset
touch "$UPDATE_GRANT"
check_grant
expect "leftover grant" grant FAIL "leftover sudo grant" "inactive" "kitchen-update --revoke"

reset
touch "$UPDATE_GRANT"
STUB_UPDATE_STATE=activating
check_grant
expect "grant during a run" grant INFO "running (activating)"

reset
touch "$UPDATE_GRANT"
STUB_UPDATE_STATE=""
check_grant
expect "grant, updater gone" grant FAIL "not loaded"

# A process that escaped the update's unit (uwsm app, systemd-run --user --scope)
# still carries the group, and the next night's rule would give it root.
reset
STUB_CARRIERS=$'4242 hyprsunset\n4250 btop\n'
check_grant
expect "carriers outside a run" grant FAIL "2 processes outside a nightly run still carry the kitchen-update group (gid 969): 4242 hyprsunset, 4250 btop" "next night's rule would give them root" "sudo kitchen-update --revoke"

reset
STUB_CARRIERS=$'4242 hyprsunset\n'
touch "$UPDATE_GRANT"
check_grant
expect "carriers and a leftover rule: root now" grant FAIL "leftover sudo grant" "1 process outside a nightly run still carries" "can run anything as root now"

reset
STUB_CARRIERS=$'4242 omarchy-update\n'
STUB_UPDATE_STATE=activating
check_grant
expect "carriers during a run are the run" grant INFO "in use while kitchen-update.service is running"

reset
STUB_GID=""
check_grant
expect "no group (updater not installed)" grant OK "no process carries its group"

# ---- nights_between -----------------------------------------------------------

n() { nights_between "$(date -d "$1" +%s)" "$(date -d "$2" +%s)"; }
expect_eq "nights mon 03:30 to thu 09:00" "$(n '2026-09-28 03:30' '2026-10-01 09:00')" 3
expect_eq "nights mon 20:00 to thu 09:00" "$(n '2026-09-28 20:00' '2026-10-01 09:00')" 3
expect_eq "nights tue 01:00 to tue 09:00" "$(n '2026-09-29 01:00' '2026-09-29 09:00')" 1
expect_eq "nights same morning" "$(n '2026-09-29 03:40' '2026-09-29 09:00')" 0
expect_eq "nights across DST end" "$(n '2026-10-31 03:30' '2026-11-03 09:00')" 3

# ---- auto-update --------------------------------------------------------------

reset
STUB_TIMER_STATES="kitchen-update.timer=not-found"
load_update_status
check_autoupdate
expect "updater not installed" auto-update INFO "not installed"

reset
STUB_TIMER_STATES="kitchen-update.timer=disabled"
load_update_status
check_autoupdate
expect "updater not enabled" auto-update INFO "not enabled" "disabled"

reset
collect_updates
status_file status-done.json
load_update_status
check_autoupdate
expect "done" auto-update OK "last night: DONE, 4 packages updated, reboot recommended"
expect_eq "done nights" "$us_nights" 0

reset
collect_updates
status_file status-done.json 5 '.reasons = ["postflight: hyprctl configerrors reports 1 error"]'
load_update_status
check_autoupdate
expect "done with notes" auto-update OK "reboot recommended: postflight: hyprctl configerrors"

reset
collect_updates
status_file status-up-to-date.json
load_update_status
check_autoupdate
expect "up to date" auto-update OK "last night: nothing to update"

reset
collect_updates
status_file status-variant.json
load_update_status
check_autoupdate
expect "variant spelling" auto-update OK "nothing to update"
expect_eq "variant reboot" "$us_reboot" recommended
expect_eq "variant reasons" "$us_reasons" "checkupdates: nothing to do after sync"

reset
collect_updates
status_file status-busy.json
load_update_status
check_autoupdate
expect "busy, recent update" auto-update INFO "last night: BUSY: remote session 18" "keyboard input 4 min ago" "next slot retries"

# The updater counted a third night without an update while 13 are pending
reset
collect_updates
now=$(date -d '2026-09-30T09:03:00-04:00' +%s)
status_file status-deferred.json
load_update_status
check_autoupdate
expect "deferred, 3 nights behind" auto-update WARN "last night: DEFERRED" "no update for 3 nights with 13 pending"
expect_has "deferred detail" "$details" '"state": "DEFERRED"'

# Its count wins while current: the last update is 4 nights back, but the
# updater saw updates pending on only one of those nights.
reset
collect_updates
now=$(date -d '2026-10-01T09:03:00-04:00' +%s)
status_file status-busy.json
load_update_status
check_autoupdate
expect "updater count wins" auto-update INFO "last night: BUSY"

# Without the count, the nights come from the last update (2026-09-27 11:18) ...
reset
collect_updates
now=$(date -d '2026-09-30T09:03:00-04:00' +%s)
status_file status-busy.json 5 'del(.nights_without_update)'
load_update_status
check_autoupdate
expect "no count, 3 nights since the update" auto-update WARN "no update for 3 nights with 13 pending"

# ... or from the last night the check-up saw settled, when that is later
reset
collect_updates
now=$(date -d '2026-09-30T09:03:00-04:00' +%s)
echo "$(date -d '2026-09-28T03:35:00-04:00' +%s) UP-TO-DATE" >"$STATE_DIR/update-nights"
status_file status-busy.json 5 'del(.nights_without_update)'
load_update_status
check_autoupdate
expect "no count, settled 2 nights ago" auto-update INFO "last night: BUSY"

# ... nor when nothing is pending
reset
STUB_CHECKUPDATES="" STUB_CHECKUPDATES_RC=2
collect_updates
now=$(date -d '2026-10-02T09:03:00-04:00' +%s)
status_file status-busy.json
load_update_status
check_autoupdate
expect "busy, nothing pending" auto-update INFO "BUSY"

reset
collect_updates
status_file status-held.json
load_update_status
check_autoupdate
expect "held" auto-update WARN "last night: HELD: Arch news since the last update" "Read the news item, then run 'omarchy update'"

reset
collect_updates
status_file status-held.json 5 '.action = "fix the held gate, or run omarchy update yourself"'
load_update_status
check_autoupdate
expect "held, the updater's own action as a sentence" auto-update WARN ". Fix the held gate, or run omarchy update yourself"

reset
collect_updates
status_file status-failed.json
load_update_status
check_autoupdate
expect "failed" auto-update FAIL "the update FAILED: postflight" "not signed; omarchy secureboot status failed" "Do not reboot yet: read /var/log/kitchen-update/2026-09-28.log before rebooting"
expect_eq "failed reboot" "$us_reboot" needed
# A clean Secure Boot status is no all-clear: a DKMS failure leaves it clean.
if [[ $(result auto-update) == *"secureboot status' is clean"* ]]; then not_ok "failed: no 'until secureboot status is clean' (a DKMS failure leaves it clean)"; else ok; fi

reset
collect_updates
status_file status-failed.json 5 '.reasons = ["nvidia: no nvidia-open-dkms module for 7.2.6-1-omarchy"] | .action = "do NOT reboot: rebuild the nvidia module with sudo dkms autoinstall -k 7.2.6-1-omarchy, then the UKI with sudo limine-mkinitcpio; then sudo kitchen-update --boot-check"'
load_update_status
check_autoupdate
expect "failed, the updater's remedy" auto-update FAIL "Do not reboot yet: do NOT reboot: rebuild the nvidia module with sudo dkms autoinstall -k 7.2.6-1-omarchy"

reset
collect_updates
status_file status-failed.json 1 '.state = "RUNNING" | .settled = false | .reasons = [] | .action = ""'
STUB_UPDATE_STATE=activating
load_update_status
check_autoupdate
expect "running now" auto-update INFO "an update is running now"

reset
collect_updates
status_file status-failed.json 3 '.state = "RUNNING" | .settled = false | .reasons = [] | .action = ""'
load_update_status
check_autoupdate
expect "RUNNING with no run behind it" auto-update FAIL "never recorded how it ended" "half-updated" "Do not reboot yet"

reset
collect_updates
status_file status-done.json 5 '.warnings = ["snapshot: omarchy update ran WITHOUT a pre-update snapshot"]'
load_update_status
check_autoupdate
expect "done, but no snapshot: WARN" auto-update WARN "DONE" "Look at: snapshot: omarchy update ran WITHOUT a pre-update snapshot"

reset
collect_updates
status_file status-held.json 5 '.warnings = ["group: killed 1 process(es) still carrying the kitchen-update group after the update: 4242 hyprsunset"]'
load_update_status
check_autoupdate
expect "held, and a killed escapee" auto-update WARN "HELD" "Look at: group: killed 1 process"

reset
collect_updates
status_file status-failed.json 5 '.reboot = {needed: true} | del(.action)'
load_update_status
check_autoupdate
expect "failed, no action" auto-update FAIL "read /var/log/kitchen-update/2026-09-28.log first"
expect_eq "failed reboot object" "$us_reboot" needed

reset
collect_updates
status_file status-truncated.json
load_update_status
check_autoupdate
expect "unreadable status" auto-update WARN "cannot read"

reset
collect_updates
now=$(date -d '2026-09-30T09:03:00-04:00' +%s)
status_file status-done.json 50
load_update_status
check_autoupdate
expect "stale done" auto-update INFO "no run last night (kitchen-update.timer enabled); last run 2026-09-28: DONE"

reset
collect_updates
now=$(date -d '2026-10-03T09:03:00-04:00' +%s)
status_file status-done.json 74
touch -d '2026-09-30T03:40:00-04:00' "$T/last-success"
load_update_status
check_autoupdate
expect "stale, 3 nights" auto-update WARN "no run last night" "no update for 3 nights with 13 pending"

reset
collect_updates
status_file status-failed.json 72
load_update_status
check_autoupdate
expect "stale failed stays FAIL" auto-update FAIL "no run last night" "FAILED"

# The history keeps one line per status write.
reset
collect_updates
status_file status-busy.json
load_update_status
check_autoupdate
check_autoupdate
expect_eq "history deduplicated" "$(wc -l <"$STATE_DIR/update-nights")" 1

# ---- reboot -------------------------------------------------------------------

reset
sb_state=clean
load_update_status
check_reboot
expect "no reboot" reboot OK "no reboot pending"

reset
sb_state=clean
STUB_KERNEL=7.2.5-4-omarchy
rm -r "$T/modules/7.2.5-4-omarchy"
mkdir -p "$T/modules/7.2.6-1-omarchy" "$T/modules/7.2.5-4-omarchy"
touch "$T/modules/7.2.6-1-omarchy/vmlinuz"
STUB_VMLINUZ_OWNED=7.2.6-1-omarchy
{ cat "$F/pacman/pacman.log"; echo '[2026-09-28T03:41:10-0400] [ALPM] upgraded linux-omarchy (7.2.5-4 -> 7.2.6-1)'; } >"$T/pacman.log"
PACMAN_LOG=$T/pacman.log
boot_verified=1
load_update_status
check_reboot
expect "kernel updated" reboot WARN "reboot pending since Mon 2026-09-28 03:41" "kernel 7.2.5-4-omarchy is running, 7.2.6-1-omarchy installed" "safe"

reset
sb_state=failing
mkdir -p "$T/home/.local/state/omarchy"
touch -d '2026-09-28T04:02:00-04:00' "$T/home/.local/state/omarchy/reboot-required"
load_update_status
check_reboot
expect "omarchy marker, sb failing" reboot WARN "since Mon 2026-09-28 04:02" "reboot-required" "do NOT reboot"

reset
STUB_HYPR_EXE="/usr/bin/Hyprland (deleted)"
{ cat "$F/pacman/pacman.log"; echo '[2026-09-28T03:41:12-0400] [ALPM] upgraded hyprland (0.56.2-3 -> 0.56.3-1)'; } >"$T/pacman.log"
PACMAN_LOG=$T/pacman.log
load_update_status
check_reboot
expect "hyprland replaced" reboot WARN "since Mon 2026-09-28 03:41" "Hyprland was replaced while running"

reset
sb_state=clean boot_verified=1
status_file status-done.json 5
load_update_status
check_reboot
expect "recommended after the update" reboot INFO "recommends a reboot (the boot chain changed: the loader was re-signed)" "safe"

# Secure Boot clean is not enough: a boot chain that failed the updater's
# checks, or a pacman cut off in its hooks, leaves it clean.
reset
sb_state=clean boot_verified=1 boot_problem="the boot chain has failed the updater's checks since 2026-09-28"
status_file status-failed.json 5
load_update_status
check_reboot
expect "sb clean, boot chain failed: not safe" reboot WARN "do NOT reboot: the boot chain has failed the updater's checks since 2026-09-28"
if [[ $(result reboot) == *"is safe"* ]]; then not_ok "sb clean, boot chain failed: never says safe"; else ok; fi

reset
sb_state=clean
status_file status-done.json 5
load_update_status
check_reboot
expect "sb clean, boot files not checked: no claim" reboot INFO "Secure Boot status is clean"
if [[ $(result reboot) == *"safe"* ]]; then not_ok "sb clean, boot files unchecked: does not say safe"; else ok; fi

reset
sb_state=clean
status_file status-failed.json 5
load_update_status
check_reboot
expect "needed per the updater" reboot WARN "reboot pending since Mon 2026-09-28 04:03" "says a reboot is needed (kernel 7.2.6-1-omarchy installed"

reset
status_file status-done.json 5
STUB_BOOT=$((now - 3600))
load_update_status
check_reboot
expect "recommended, already rebooted" reboot OK "no reboot pending"

# The updater's reboot-pending record keeps the night it asked, through the
# nights after it (status.json is rewritten every night).
reboot_pending() { # boot-id since level reason
  jq -n --arg b "$1" --arg s "$2" --arg l "$3" --arg r "$4" \
    '{since: $s, level: $l, reasons: [$r], boot_id: $b}' >"$T/reboot-pending"
}

reset
sb_state=clean boot_verified=1
STUB_BOOT=$(date -d '2026-09-26T20:00:00-04:00' +%s)
status_file status-busy.json 6 '.reboot = "needed" | .reboot_reasons = ["kernel updated: running 7.2.5-4-omarchy, installed 7.2.6-1-omarchy"]'
reboot_pending "$STUB_BOOT_ID" 2026-09-27T03:41:00-04:00 needed "kernel updated: running 7.2.5-4-omarchy, installed 7.2.6-1-omarchy"
load_update_status
check_reboot
expect "reboot-pending: since the night it was asked" reboot WARN "reboot pending since Sun 2026-09-27 03:41: the last update says a reboot is needed (kernel updated" "safe"

reset
reboot_pending "$STUB_BOOT_ID" "" needed "Omarchy marked a reboot as required"
load_update_status
check_reboot
expect "reboot-pending: no date, no made-up date" reboot WARN "reboot pending: the last update says a reboot is needed (Omarchy marked"

reset
STUB_BOOT=$(date -d '2026-09-28T01:00:00-04:00' +%s)
reboot_pending 0d1e2f30-0000-4000-8000-000000000000 2026-09-27T03:41:00-04:00 needed "kernel updated"
status_file status-busy.json 6
load_update_status
check_reboot
expect "reboot-pending: from an earlier boot, so done" reboot OK "no reboot pending"

reset
sb_state=clean
reboot_pending 0d1e2f30-0000-4000-8000-000000000000 2026-09-27T03:41:00-04:00 needed "kernel updated"
status_file status-done.json 5
load_update_status
check_reboot
expect "reboot-pending stale: the status after this boot still counts" reboot INFO "recommends a reboot (the boot chain changed"

reset
reboot_pending "$STUB_BOOT_ID" 2026-09-28T03:52:10-04:00 recommended "the UKI was rebuilt"
load_update_status
check_reboot
expect "reboot-pending: recommended" reboot INFO "recommends a reboot (the UKI was rebuilt)"

# ---- boot chain ---------------------------------------------------------------

reset
check_boot_chain
expect "boot chain ok" boot-chain OK "the UKI on the ESP matches 7.2.5-4-omarchy" "nvidia-open-dkms module is built"
expect_eq "boot chain ok: verified" "$boot_verified" 1

reset
STUB_UKI_UNAME=7.2.4-1-omarchy
check_boot_chain
expect "stale UKI" boot-chain FAIL "carries '7.2.4-1-omarchy', not kernel 7.2.5-4-omarchy" "Do NOT reboot" "limine-mkinitcpio"
expect_has "stale UKI: a reason for the reboot line" "$boot_problem" "boot files are wrong"

reset
rm "$T/boot/omarchy_linux-omarchy.efi"
check_boot_chain
expect "missing UKI" boot-chain FAIL "omarchy_linux-omarchy.efi is missing for kernel 7.2.5-4-omarchy"

reset
STUB_DKMS_BUILT=""
check_boot_chain
expect "no nvidia module (Secure Boot stays clean)" boot-chain FAIL "no nvidia-open-dkms module for kernel 7.2.5-4-omarchy" "dkms autoinstall"

reset
STUB_NVIDIA=""
STUB_DKMS_BUILT=""
check_boot_chain
expect "no nvidia DKMS installed: no module needed" boot-chain OK "matches 7.2.5-4-omarchy"

reset
jq -n '{night: "2026-09-28", since: "2026-09-28T04:12:40-04:00", reasons: ["dkms: a DKMS build failed: exited 10"], action: "do NOT reboot: rebuild the nvidia module with sudo dkms autoinstall, then the UKI with sudo limine-mkinitcpio; then sudo kitchen-update --boot-check"}' >"$T/boot-check"
check_boot_chain
expect "the updater's record stands" boot-chain FAIL "the nightly update of 2026-09-28 left a boot chain that failed its checks: dkms: a DKMS build failed" "Do NOT reboot" "sudo kitchen-update --boot-check"
expect_eq "the record: not verified" "$boot_verified" 0
expect_has "the record: a reason for the reboot line" "$boot_problem" "since 2026-09-28"

reset
rm -r "$T/modules/7.2.5-4-omarchy"
check_boot_chain
expect "no kernel found" boot-chain WARN "no package-owned kernel"

# ---- units and services -------------------------------------------------------

reset
check_failed_units
expect "known failures only" units OK "3 known NvPCR failures ignored"

reset
{ cat "$F/failed-units.txt"; echo 'kitchen-update.service           loaded failed failed kitchen-sink nightly update'; } >"$T/failed"
STUB_FAILED=$T/failed
STUB_USER_FAILED=$'elephant.service loaded failed failed Walker data provider\n'
check_failed_units
expect "new failures" units FAIL "2 failed: kitchen-update.service user:elephant.service"

reset
STUB_SESSION=1
STUB_USER_FAILED="should-not-be-read.service loaded failed failed x"
check_failed_units
expect "no session, no user units" units OK

reset
STUB_INACTIVE="ollama.service ufw.service"
check_services
expect "services down" services WARN "not active: ufw.service ollama.service"

# ---- space and mounts ---------------------------------------------------------

reset
check_space
expect "root space ok" space OK "/ has 415 GiB free"
expect "esp ok" esp OK "/boot has 1230 MiB free"
expect "data ok" data-space OK "/mnt/data is 1% full"

reset
printf '    Free (estimated):\t\t %s\t(min: 1)\n' $((30 * 1024 ** 3)) >"$T/usage"
STUB_USAGE=$T/usage STUB_BOOT_FREE=$((600 * 1024 ** 2)) STUB_DATA_PCT=93
check_space
expect "root warn" space WARN "30 GiB"
expect "esp warn" esp WARN "600 MiB"
expect "data warn" data-space WARN "93% full"

reset
printf '    Free (estimated):\t\t %s\t(min: 1)\n' $((10 * 1024 ** 3)) >"$T/usage"
STUB_USAGE=$T/usage STUB_BOOT_FREE=$((300 * 1024 ** 2))
check_space
expect "root fail" space FAIL "10 GiB"
expect "esp fail" esp FAIL "300 MiB" "UKI may not fit"

reset
STUB_USAGE=/dev/null STUB_ROOT_DF=$((20 * 1024 ** 3))
check_space
expect "root via df" space WARN "20 GiB"

reset
STUB_USAGE=/dev/null STUB_ROOT_DF="" STUB_MOUNTED="/"
check_space
expect "root unreadable" space WARN "cannot read"
expect_none "data unmounted, no data-space" data-space

reset
check_data_mount
expect "data mount ok" data-mount OK "mounted rw"

reset
STUB_DATA_SRC=""
check_data_mount
expect "data not mounted" data-mount FAIL "not mounted"

reset
STUB_DATA_SRC=/dev/nvme0n1p1
check_data_mount
expect "data wrong source" data-mount FAIL "comes from /dev/nvme0n1p1"

reset
STUB_DATA_OPTS=ro,noatime,compress=zstd:1
check_data_mount
expect "data read-only" data-mount FAIL "read-only"

# ---- NVMe ---------------------------------------------------------------------

# With no names configured, every drive the helper found is checked by serial.
reset
NVME_SERIALS=""
check_nvme
expect "nvme unnamed system drive" nvme-SYSDRIVE0001 OK "SYSDRIVE0001: 1% used"
expect "nvme unnamed data drive" nvme-DATADRIVE0001 OK "DATADRIVE0001: 17% used"

NVME_SERIALS="SYSDRIVE0001:system DATADRIVE0001:data"
reset
check_nvme
expect "nvme baseline system" nvme-system OK "SYSDRIVE0001: 1% used, spare 100%, 34C, media errors 0, error log +0"
expect "nvme baseline data" nvme-data OK "DATADRIVE0001: 17% used"
expect_has "nvme state saved" "$(cat "$STATE_DIR/nvme.json")" '"SYSDRIVE0001"'

# The next day: the FireCuda's error log grew (INFO), the WDC ran hot for a minute (WARN)
reset
cp "$F/nvme-health.json" "$STATE_DIR/nvme.json"
jq '."SYSDRIVE0001".error_log_entries += 18 | ."DATADRIVE0001".crit_temp_minutes += 1' "$F/nvme-health.json" >"$T/nvme-now.json"
check_nvme
expect "nvme error log grew" nvme-system INFO "error log +18"
expect "nvme crit temp minutes" nvme-data WARN "+1 min above critical temperature"

reset
cp "$F/nvme-health.json" "$STATE_DIR/nvme.json"
jq '."SYSDRIVE0001".media_errors += 2 | ."DATADRIVE0001".critical_warning = 4' "$F/nvme-health.json" >"$T/nvme-now.json"
check_nvme
expect "nvme new media errors" nvme-system FAIL "+2 media errors"
expect "nvme critical warning" nvme-data FAIL "critical_warning=4"

# The day after, the same two media errors are old news: WARN, not FAIL
reset
jq '."SYSDRIVE0001".media_errors += 2' "$F/nvme-health.json" >"$T/nvme-now.json"
cp "$T/nvme-now.json" "$STATE_DIR/nvme.json"
check_nvme
expect "nvme old media errors" nvme-system WARN "2 media errors (unchanged)"

reset
jq '."DATADRIVE0001".percentage_used = 85 | ."DATADRIVE0001".temperature_c = 71 | ."DATADRIVE0001".available_spare = 3' "$F/nvme-health.json" >"$T/nvme-now.json"
check_nvme
expect "nvme spare below threshold" nvme-data FAIL "spare 3% below its 4% threshold"

reset
jq '."DATADRIVE0001".percentage_used = 85 | ."DATADRIVE0001".temperature_c = 71' "$F/nvme-health.json" >"$T/nvme-now.json"
check_nvme
expect "nvme worn and hot" nvme-data WARN "85% of rated life used; 71C"

# A drive that failed to answer keeps its last good reading for next time.
reset
cp "$F/nvme-health.json" "$STATE_DIR/nvme.json"
jq '."DATADRIVE0001" = {"ctrl": "nvme0", "error": "[Errno 5] Input/output error"} | del(."SYSDRIVE0001")' "$F/nvme-health.json" >"$T/nvme-now.json"
check_nvme
expect "nvme read error" nvme-data FAIL "SMART read failed: [Errno 5]"
expect "nvme drive gone" nvme-system FAIL "drive not found"
expect_eq "nvme state keeps last good" "$(jq -r '."DATADRIVE0001".power_on_hours' "$STATE_DIR/nvme.json")" 29508

reset
echo 'Traceback (most recent call last):' >"$T/nvme-now.json"
check_nvme
expect "nvme helper broken" nvme FAIL "no drive data"

# critical_warning bit 1 (temperature) on the armed system drive, warm past the
# 70C threshold the daemon lowered but far below its own 90C: WARN, not FAIL.
reset
jq '."SYSDRIVE0001".critical_warning = 2 | ."SYSDRIVE0001".temperature_c = 72' "$F/nvme-health.json" >"$T/nvme-now.json"
check_nvme
expect "nvme bit 1 on an armed drive" nvme-system WARN "critical_warning=2 (temperature): past a threshold the thermal daemon set (over 70C; the drive limit is 90C)" "72C"

# An armed drive past its own limit, as the daemon leaves it: the over
# threshold moved out of reach (65535 K, 65262C), so bit 1 is clear. The
# temperature itself is the FAIL.
reset
jq '.SYSDRIVE0001.temp_over.current_k = 65535 | .SYSDRIVE0001.temp_over.current_c = 65262
  | .SYSDRIVE0001.temp_under.current_c = 75' "$T/nvme-probe.json" >"$T/p" && mv "$T/p" "$T/nvme-probe.json"
jq '."SYSDRIVE0001".critical_warning = 0 | ."SYSDRIVE0001".temperature_c = 91' "$F/nvme-health.json" >"$T/nvme-now.json"
check_nvme
expect "nvme armed drive above its limit" nvme-system FAIL "91C, at or above the drive limit 90C (armed: bit 1 of critical_warning does not show it)"

# ... and afterwards, cooled down: the minutes it counted above its limit
reset
cp "$F/nvme-health.json" "$STATE_DIR/nvme.json"
jq '."SYSDRIVE0001".warn_temp_minutes += 3' "$F/nvme-health.json" >"$T/nvme-now.json"
check_nvme
expect "nvme armed drive was above its limit" nvme-system FAIL "+3 min at or above the drive limit 90C since the last check-up"

# The same minutes on a drive nobody arms: its own bit 1 said so at the time
reset
cp "$F/nvme-health.json" "$STATE_DIR/nvme.json"
jq '."DATADRIVE0001".warn_temp_minutes += 3' "$F/nvme-health.json" >"$T/nvme-now.json"
check_nvme
expect "nvme unarmed drive above warning temperature" nvme-data WARN "+3 min above warning temperature"

# Bit 1 past the limit on a drive the daemon does not hold is a hot drive
reset
jq '.SYSDRIVE0001.armed = false | .SYSDRIVE0001.temp_over.current_c = 90' "$T/nvme-probe.json" >"$T/p" && mv "$T/p" "$T/nvme-probe.json"
jq '."SYSDRIVE0001".critical_warning = 2 | ."SYSDRIVE0001".temperature_c = 91' "$F/nvme-health.json" >"$T/nvme-now.json"
check_nvme
expect "nvme bit 1 above the drive limit" nvme-system FAIL "critical_warning=2"

# Bit 1 with any other bit, or on a drive nobody arms, stays a FAIL.
reset
jq '."SYSDRIVE0001".critical_warning = 6 | ."SYSDRIVE0001".temperature_c = 72' "$F/nvme-health.json" >"$T/nvme-now.json"
check_nvme
expect "nvme bit 1 plus reliability" nvme-system FAIL "critical_warning=6"
reset
printf 'NVME_ARM=""\n' >"$T/thermal.conf"
jq '."SYSDRIVE0001".critical_warning = 2 | ."SYSDRIVE0001".temperature_c = 72' "$F/nvme-health.json" >"$T/nvme-now.json"
check_nvme
expect "nvme bit 1, drive not armed" nvme-system FAIL "critical_warning=2"
expect_eq "nvme: no probe without a drive to arm" "$nvme_probe_json" ""
reset
jq '."DATADRIVE0001".critical_warning = 2 | ."DATADRIVE0001".temperature_c = 66' "$F/nvme-health.json" >"$T/nvme-now.json"
check_nvme
expect "nvme bit 1 on the unarmed data drive" nvme-data FAIL "critical_warning=2"

# ---- thermal events ------------------------------------------------------------

reset
check_thermal
expect "thermal all events" thermal OK "active; events from uevent nct6775 nvme nvml kmsg"

reset
jq '.sources.nct6775 |= (.mode = "degraded" | .reason = "the loaded nct6775 has no change notification (stock driver); polling every 10 s" | .cpu.level = "warn")' \
  "$F/thermal/state-event.json" >"$T/thermal-state.json"
check_thermal
expect "thermal degraded" thermal WARN "DEGRADED, polled instead: nct6775 (the loaded nct6775 has no change notification (stock driver); polling every 10 s)" "now: cpu warn"

reset
jq '.sources.nvml = {"mode": "off", "reason": "no NVIDIA GPU"} | .sources.kmsg = "off"' "$F/thermal/state-event.json" >"$T/thermal-state.json"
check_thermal
expect "thermal a source off" thermal INFO "off: nvml (no NVIDIA GPU), kmsg"

# Off because it broke, announced as degraded and not restored: a WARN
reset
jq '.sources.nvml = {"mode": "off", "reason": "the GPU is lost (fallen off the bus)", "announced": "the GPU is lost (fallen off the bus)"}' \
  "$F/thermal/state-event.json" >"$T/thermal-state.json"
check_thermal
expect "thermal nvml lost" thermal WARN "DOWN since it was announced degraded: nvml (the GPU is lost (fallen off the bus))"
reset
jq '.sources.kmsg = {"mode": "off", "reason": "journalctl exited (1) after 0 s; restarting in 20 s", "announced": true}
  | .sources.nct6775 |= (.mode = "off" | .reason = "no nct6799 hwmon device (nct6775 not loaded?)" | .announced = ["off", .reason])' \
  "$F/thermal/state-event.json" >"$T/thermal-state.json"
check_thermal
expect "thermal kmsg and nct6775 down" thermal WARN "DOWN since it was announced degraded: nct6775 (no nct6799 hwmon device" "kmsg (journalctl exited"

# What is not normal right now is listed: a warm drive, a hot GPU, a stalled fan
reset
jq '.sources.nvme.drives.system.level = "warn" | .sources.nvml.gpu.hot = true | .sources.nvml.gpu.throttling = ["sw-thermal"]
  | .sources.nct6775.fans.fan5.stalled = true' "$F/thermal/state-event.json" >"$T/thermal-state.json"
check_thermal
expect "thermal levels" thermal OK "now: nvme-system warn, gpu hot, gpu throttling sw-thermal, fan5 stalled"

# The design's name for the version key, and its top-level levels, read too
reset
jq 'del(.version) | .schema = 1 | .levels = {"cpu": "crit"} | del(.sources.nct6775.cpu)' "$F/thermal/state-event.json" >"$T/thermal-state.json"
check_thermal
expect "thermal schema key" thermal OK "now: cpu crit"

reset
STUB_THERMAL_PID=4321
check_thermal
expect "thermal stale state" thermal WARN "active (pid 4321), but $T/thermal-state.json was written by pid 1234"

reset
jq '.sources = {}' "$F/thermal/state-event.json" >"$T/thermal-state.json"
check_thermal
expect "thermal no sources" thermal WARN "no source sends events"

reset
STUB_THERMAL_ACTIVE=failed
check_thermal
expect "thermal daemon down" thermal WARN "kitchen-thermal.service is failed (enabled)" "sudo systemctl enable --now kitchen-thermal.service"

reset
STUB_THERMAL_LOAD=not-found
check_thermal
expect "thermal not installed" thermal WARN "not installed"
check_thermal_events
expect_none "thermal events: none without the daemon" thermal-events

reset
rm "$T/thermal-state.json"
check_thermal
expect "thermal no state" thermal WARN "missing or unreadable"

reset
echo '{"version": 2, "sources": {}}' >"$T/thermal-state.json"
check_thermal
expect "thermal version" thermal WARN "version '2', not 1"

# The patched nct6775, as its notify_interval shows it
reset
check_nct6775
expect "nct6775 patched" nct6775 OK "the patched nct6775 is loaded (nct6775-notify-dkms 7.2.5.1-1, /lib/modules/7.2.5-4-omarchy/updates/dkms/nct6775-core.ko.zst): notify_interval=1000 ms"

# A 7.2 kernel newer than the last release its sources were checked against
reset
STUB_KERNEL=7.2.9-1-omarchy
check_nct6775
expect "nct6775 on a kernel newer than checked" nct6775 INFO "last checked against Linux 7.2.8, and this kernel is 7.2.9" "refresh.sh 7.2.9 --record"
reset
STUB_KERNEL=7.2.8-2-omarchy
check_nct6775
expect "nct6775 on the checked kernel" nct6775 OK "notify_interval=1000 ms"
reset
printf '# version: 7.2.5\n' >"$T/doc/upstream.sha256"
STUB_KERNEL=7.2.6-1-omarchy
check_nct6775
expect "nct6775 without checked-through: the version" nct6775 INFO "last checked against Linux 7.2.5"

reset
echo 0 >"$T/nct6775_core/parameters/notify_interval"
check_nct6775
expect "nct6775 notifications off" nct6775 WARN "notify_interval=0"

reset
rm "$T/nct6775_core/parameters/notify_interval"
check_nct6775
expect "nct6775 in-tree loaded, patched built" nct6775 WARN "the in-tree nct6775 is loaded" "sudo modprobe -r nct6775 nct6775_core && sudo modprobe nct6775"

reset
rm "$T/nct6775_core/parameters/notify_interval"
STUB_THERMAL_PKG="" STUB_NCT_FILE=/lib/modules/7.2.5-4-omarchy/kernel/drivers/hwmon/nct6775-core.ko.zst
check_nct6775
expect "nct6775 package missing" nct6775 WARN "nct6775-notify-dkms is not installed"

reset
rm "$T/nct6775_core/parameters/notify_interval"
STUB_NCT_FILE=/lib/modules/7.3.1-1-omarchy/kernel/drivers/hwmon/nct6775-core.ko.zst STUB_KERNEL=7.3.1-1-omarchy
check_nct6775
expect "nct6775 no module for this kernel" nct6775 WARN "built no module for 7.3.1-1-omarchy" "BUILD_EXCLUSIVE_KERNEL"

reset
rm -r "$T/nct6775_core"
check_nct6775
expect "nct6775 not loaded" nct6775 WARN "nct6775 is not loaded"

# The drives NVME_ARM names, through the X0 probe
reset
check_nvme
check_nvme_arm
expect "nvme-arm system armed" nvme-arm-system OK "SYSDRIVE0001: armed (FID 0Bh 0x00000202, case A): events above 70C and below -60C; levels 70/80C, clear 65C; the drive limit 90C"
expect_none "nvme-arm: only the drives NVME_ARM names" nvme-arm-data

# kitchen-sink as X0 found it: the kernel's 0x200, no bit 1, thresholds untouched
reset
cp "$F/nvme-probe.json" "$T/nvme-probe.json"
check_nvme_arm
expect "nvme-arm not armed" nvme-arm-system WARN "not armed: FID 0Bh is 0x00000200, without bit 1"

reset
printf 'NVME_ARM="system data"   # both\n' >"$T/thermal.conf"
check_nvme_arm
expect "nvme-arm the data drive is case B" nvme-arm-data WARN "case B (OAES 0x00000000" "Take it out of NVME_ARM"
expect "nvme-arm quoted list" nvme-arm-system OK "armed"

reset
printf 'NVME_ARM=DATADRIVE0001\n' >"$T/thermal.conf"
check_nvme_arm
expect "nvme-arm by serial" nvme-arm-data WARN "case B"

reset
printf 'NVME_ARM=scratch\n' >"$T/thermal.conf"
check_nvme_arm
expect "nvme-arm unknown name" nvme-arm-scratch WARN "neither a role in NVME_SERIALS"

reset
jq 'del(.SYSDRIVE0001)' "$T/nvme-probe.json" >"$T/p" && mv "$T/p" "$T/nvme-probe.json"
check_nvme_arm
expect "nvme-arm drive gone" nvme-arm-system WARN "drive not found by the probe"

reset
echo 'Traceback' >"$T/nvme-probe.json"
check_nvme_arm
expect "nvme-arm probe broken" nvme-arm WARN "printed no drive data"

reset
jq '.SYSDRIVE0001.temp_over.current_c = 60' "$T/nvme-probe.json" >"$T/p" && mv "$T/p" "$T/nvme-probe.json"
check_nvme_arm
expect "nvme-arm threshold set by hand" nvme-arm-system WARN "60C is not a threshold the daemon sets (70C, 80C or the drive's 90C)"

reset
jq '.SYSDRIVE0001.temp_over.current_c = 90' "$T/nvme-probe.json" >"$T/p" && mv "$T/p" "$T/nvme-probe.json"
check_nvme
check_nvme_arm
expect "nvme-arm armed but not lowered while cool" nvme-arm-system WARN "At 34C the daemon should have lowered it to 70C"

# Past the drive's own limit the daemon turns the over threshold off (0xFFFF K)
reset
jq '.SYSDRIVE0001.temp_over.current_k = 65535 | .SYSDRIVE0001.temp_over.current_c = 65262
  | .SYSDRIVE0001.temp_under.current_c = 75' "$T/nvme-probe.json" >"$T/p" && mv "$T/p" "$T/nvme-probe.json"
check_nvme_arm
expect "nvme-arm hot level" nvme-arm-system OK "no over-temperature event while this hot and below 75C"

reset
printf 'NVME_ARM=system\nNVME_system_WARN=68 # cooler\nNVME_system_CRIT="78"\n' >"$T/thermal.conf"
jq '.SYSDRIVE0001.temp_over.current_c = 68' "$T/nvme-probe.json" >"$T/p" && mv "$T/p" "$T/nvme-probe.json"
check_nvme_arm
expect "nvme-arm levels from thermal.conf" nvme-arm-system OK "events above 68C" "levels 68/78C, clear 65C"

reset
: >"$T/thermal.conf"
check_nvme_arm
expect "nvme-arm nothing armed" nvme-arm INFO "names no drive"
rm "$T/thermal.conf"
reset
rm "$T/thermal.conf"
check_nvme_arm
expect_none "nvme-arm: no thermal.conf, no row" nvme-arm

# conf_value reads the daemon's file without sourcing it
printf 'A=1\n#B=2\n  C="x y" # note\nD='"'"'q'"'"'\nA=3\n' >"$T/kv.conf"
expect_eq "conf_value: the last one wins" "$(conf_value "$T/kv.conf" A)" 3
expect_eq "conf_value: commented out is unset" "$(conf_value "$T/kv.conf" B)" ""
expect_eq "conf_value: quotes and comment dropped" "$(conf_value "$T/kv.conf" C)" "x y"
expect_eq "conf_value: single quotes" "$(conf_value "$T/kv.conf" D)" "q"
expect_eq "conf_value: missing file" "$(conf_value "$T/no-such.conf" A)" ""

# Events and hook failures in the daemon's journal over 24 h
reset
check_thermal_events
expect "thermal events counted" thermal-events OK "24 h: 5 events (cpu-hot x1, fan-ramp x3, nvme-hot x1), no hook failures; 1 hook skipped: nobody logged in"

# Not one hook ran all day, every one skipped for want of a user manager: what
# a service that cannot see the session looks like
reset
jq -c 'if .KITCHEN_HOOK == "queued" then .KITCHEN_HOOK = "no-user-manager" else . end
  | select(.KITCHEN_HOOK_RESULT != "ok")' "$F/thermal/journal-day.json" >"$T/j.json"
STUB_THERMAL_JOURNAL=$T/j.json
check_thermal_events
expect "thermal hooks all skipped" thermal-events INFO "not one hook ran; 6 hooks skipped: nobody logged in" "--test-event"

# A hook user that does not exist is a setting to fix
reset
jq -c 'if .KITCHEN_EVENT == "nvme-hot" then .KITCHEN_HOOK = "no-user" else . end' "$F/thermal/journal-day.json" >"$T/j.json"
STUB_THERMAL_JOURNAL=$T/j.json
check_thermal_events
expect "thermal no such hook user" thermal-events WARN "1 hook failure: no hook for nvme-hot: the hook user does not exist"

# A hook that failed or timed out, and one that could not be queued; a skipped
# one (no user manager) and a --test-event's are not failures.
reset
STUB_THERMAL_JOURNAL=$F/thermal/journal-hook-failed.json
check_thermal_events
expect "thermal hook failures" thermal-events WARN "24 h: 7 events (cpu-hot x1, fan-ramp x4, fan-stall x1, nvme-hot x1); 3 hook failures: hook for fan-stall start (event 8): failed (exit 1: Hook failed:" "journalctl -t kitchen-thermal"

# A hook script that fails is invisible to the daemon (omarchy-hook exits 0);
# omarchy-hook's own line counts, for thermal hooks only.
reset
STUB_HOOK_JOURNAL=$'Hook failed: /home/kevinwyckoff/.config/omarchy/hooks/thermal.d/30-fans\nHook failed: /home/kevinwyckoff/.config/omarchy/hooks/post-update.d/10-x\n'
check_thermal_events
expect "thermal hook script failed" thermal-events WARN "5 events" "1 hook failure: Hook failed: /home/kevinwyckoff/.config/omarchy/hooks/thermal.d/30-fans"

reset
STUB_THERMAL_JOURNAL=/dev/null
check_thermal_events
expect "thermal quiet day" thermal-events OK "no thermal events"

# ---- btrfs and scrub ----------------------------------------------------------

started=$(date -d 'Mon Sep 28 12:34:49 2026' +%s)

reset
now=$((started + 10 * 86400))
check_btrfs
expect "btrfs stats clean" "btrfs /" OK "all zero"
expect "scrub finished" "scrub /" OK "last scrub 10 day(s) ago, no errors"
expect "scrub data finished" "scrub /mnt/data" OK

reset
now=$((started + 45 * 86400))
check_btrfs
expect "scrub old" "scrub /" WARN "45 days ago (finished)" "btrfs-scrub@-.timer"
expect "scrub data old" "scrub /mnt/data" WARN "btrfs-scrub@mnt-data.timer"

reset
STUB_SCRUB_root=$F/btrfs/scrub-never.txt
check_btrfs
expect "scrub never, timer enabled" "scrub /" INFO "not scrubbed yet; btrfs-scrub@-.timer is enabled and scrubs monthly"

reset
STUB_SCRUB_root=$F/btrfs/scrub-never.txt
STUB_TIMER_STATES="btrfs-scrub@-.timer=disabled"
check_btrfs
expect "scrub never, timer off" "scrub /" INFO "never scrubbed (enable btrfs-scrub@-.timer)"

reset
now=$((started + 86400))
STUB_SCRUB_root=$F/btrfs/scrub-errors.txt STUB_STATS_root=$F/btrfs/stats-errors.txt
check_btrfs
expect "btrfs device errors" "btrfs /" FAIL "corruption_errs 4"
expect "scrub errors" "scrub /" FAIL "csum=1" "Corrected 0, Uncorrectable 1, Unverified 0"

reset
now=$((started + 2 * 86400))
STUB_SCRUB_root=$F/btrfs/scrub-aborted.txt
check_btrfs
expect "scrub aborted" "scrub /" INFO "was aborted before the end"

reset
STUB_SCRUB_root=$F/btrfs/scrub-running.txt
check_btrfs
expect "scrub running" "scrub /" INFO "running now"

reset
echo "ERROR: cannot access '/': Permission denied" >"$T/scrub-bad"
STUB_SCRUB_root=$T/scrub-bad
check_btrfs
expect "scrub unreadable" "scrub /" WARN "Permission denied"

reset
STUB_MOUNTED="/"
check_btrfs
expect_none "unmounted data skipped" "btrfs /mnt/data"

# ---- time and updates ---------------------------------------------------------

reset
check_time
expect "ntp ok" time OK

reset
STUB_NTP=no
check_time
expect "ntp not synced" time WARN "NTPSynchronized=no"

reset
check_last_update
expect "last update fresh" last-update OK "0 day(s) ago (2026-09-27T11:18:36-0400)"

reset
now=$(date -d '2026-10-05T09:00:00-04:00' +%s)
check_last_update
expect "last update 7 days" last-update WARN "7 days ago"

reset
now=$(date -d '2026-10-19T09:00:00-04:00' +%s)
check_last_update
expect "last update 21 days" last-update FAIL "21 days ago"

reset
PACMAN_LOG=/dev/null
check_last_update
expect "no upgrade in log" last-update WARN "no full system upgrade"

reset
check_transaction
expect_none "transactions complete" transaction
expect_none "no stale lock" pacman-lock

reset
{ cat "$F/pacman/pacman.log"; printf '%s\n' '[2026-09-28T03:41:00-0400] [ALPM] transaction started' '[2026-09-28T03:41:05-0400] [ALPM] upgraded glibc (2.44+r24+g16be1518495f-1 -> 2.44+r50+g1848099f063e-1)'; } >"$T/pacman.log"
PACMAN_LOG=$T/pacman.log
check_transaction
expect "interrupted transaction" transaction FAIL "started 2026-09-28T03:41:00-0400 never finished"

reset
PACMAN_LOG=$T/pacman.log STUB_PACMAN_RUNNING=0
check_transaction
expect "transaction running" transaction INFO "running now"

reset
{ cat "$F/pacman/pacman.log"; printf '%s\n' '[2026-09-28T03:41:00-0400] [ALPM] transaction started' '[2026-09-28T03:41:02-0400] [ALPM] transaction failed'; } >"$T/pacman.log"
PACMAN_LOG=$T/pacman.log
check_transaction
expect "failed transaction" transaction WARN "failed"

# pacman.log says "transaction completed" before the post-transaction hooks:
# the fixture ends in them, so with its lock left, pacman died there.
reset
touch "$T/db.lck"
check_transaction
expect "stale lock, died in the hooks" pacman-lock FAIL "pacman died during its post-transaction hooks" "Do NOT reboot" "reinstall the kernel packages (or run limine-mkinitcpio)"
expect_none "stale lock, died in the hooks: the log alone looks complete" transaction
expect_has "stale lock: a reason for the reboot line" "$boot_problem" "post-transaction hooks"

reset
{ cat "$F/pacman/pacman.log"; echo "[2026-09-28T10:00:00-0400] [PACMAN] Running 'pacman -Sy'"; } >"$T/pacman.log"
PACMAN_LOG=$T/pacman.log
touch "$T/db.lck"
check_transaction
expect "stale lock, elsewhere" pacman-lock FAIL "exists with no package manager running: pacman died" "Do NOT reboot"

reset
touch "$T/db.lck"
STUB_PACMAN_RUNNING=0
check_transaction
expect_none "a lock while pacman runs is fine" pacman-lock

reset
collect_updates
check_pending
expect "pending" updates INFO "13 pending"
expect_has "pending detail" "$details" "limine 12.9.0-1 -> 12.9.1-1"
expect_has "held back detail" "$details" "[ignored]"

reset
STUB_CHECKUPDATES="" STUB_CHECKUPDATES_RC=2 STUB_QU=""
collect_updates
check_pending
expect "nothing pending" updates OK "no pending updates"
expect_eq "pending count zero" "$pending_count" 0

reset
STUB_CHECKUPDATES="" STUB_CHECKUPDATES_RC=1
collect_updates
check_pending
expect "checkupdates failed" updates WARN "exit 1"
expect_eq "pending unknown" "$pending_count" -1
expect_eq "no held-back lookup without a DB" "$held_back" ""

reset
STUB_CHECKUPDATES_RC=2 STUB_CHECKUPDATES=""
STUB_PACNEW=$'/etc/pacman.conf.pacnew\n/etc/mkinitcpio.conf.pacsave\n'
collect_updates
check_pending
expect "pacnew" pacnew INFO "2 files to merge"

# ---- journal ------------------------------------------------------------------

reset
STUB_JOURNAL=$F/journal/errors-short-iso.txt
check_journal
expect "journal real day" journal WARN "2 unexpected error lines since -24h (60 before the noise filter)"
expect_has "journal detail" "$details" "sudo: pam_unix(sudo:auth): conversation failed"
expect_none "no coredumps" coredumps

reset
grep -v 'sudo\[' "$F/journal/errors-short-iso.txt" >"$T/journal"
echo '2026-09-28T09:03:01-04:00 kitchen-sink kitchen-checkup[4242]: <3>FAIL secureboot: yesterday' >>"$T/journal"
STUB_JOURNAL=$T/journal
date -d "@$((now - 86400))" -Is >"$STATE_DIR/last-run"
check_journal
expect "journal all noise" journal OK "no unexpected errors since 2026-09-27" "59 known-noise lines"

# The updater's sudo probes are its own; any other refused sudo still counts.
reset
{
  echo '2026-09-28T02:41:07-04:00 kitchen-sink sudo[81234]: kevinwyckoff : a password is required ; PWD=/ ; USER=root ; COMMAND=/usr/bin/true kitchen-update-probe'
  echo '2026-09-28T02:58:40-04:00 kitchen-sink sudo[81990]:     desk : a password is required ; PWD=/ ; USER=root ; COMMAND=/usr/bin/true kitchen-update-probe'
  echo '2026-09-28T03:10:02-04:00 kitchen-sink sudo[82001]: kevinwyckoff : a password is required ; PWD=/home/kevinwyckoff ; USER=root ; COMMAND=/usr/bin/pacman -Syu'
  echo '2026-09-28T03:10:09-04:00 kitchen-sink sudo[82002]: kevinwyckoff : a password is required ; PWD=/ ; USER=root ; COMMAND=/usr/bin/true kitchen-update-probe-not ; extra'
} >"$T/journal"
STUB_JOURNAL=$T/journal
check_journal
expect "sudo probes filtered, other refusals kept" journal WARN "2 unexpected error lines" "(4 before the noise filter)"
expect_has "refused pacman still reported" "$details" "COMMAND=/usr/bin/pacman -Syu"
reset
JOURNAL_IGNORE=$T/no-such-file
STUB_JOURNAL=$T/journal
check_journal
expect "sudo probes filtered by the built-in fallback" journal WARN "2 unexpected error lines"

# The AX210 Wi-Fi card's start-up lines, from kitchen-sink's boot on 2026-10-01,
# plus a made-up firmware crash that must still show. The hub re-enabling a
# port stays too: it can point at the Bluetooth cable.
reset
{
  echo '2026-10-01T13:43:04-04:00 kitchen-sink kernel: usb usb1-port8: disabled by hub (EMI?), re-enabling...'
  echo '2026-10-01T13:43:04-04:00 kitchen-sink kernel: Bluetooth: hci0: No support for _PRR ACPI method'
  echo '2026-10-01T13:43:06-04:00 kitchen-sink wpa_supplicant[1460]: wlp6s0: nl80211: kernel reports: multicast RX registrations are not supported'
  echo '2026-10-01T13:43:06-04:00 kitchen-sink wpa_supplicant[1460]: p2p-dev-wlp6s0: nl80211: kernel reports: multicast RX registrations are not supported'
  echo '2026-10-01T13:44:03-04:00 kitchen-sink kernel: iwlwifi 0000:06:00.0: Not associated and the session protection is over already...'
  echo '2026-10-01T13:44:05-04:00 kitchen-sink kernel: iwlwifi 0000:06:00.0: Not associated and the session protection is over already...'
  echo '2026-10-01T13:44:06-04:00 kitchen-sink kernel: iwlwifi 0000:06:00.0: Microcode SW error detected. Restarting 0x0.'
} >"$T/journal"
STUB_JOURNAL=$T/journal
check_journal
expect "AX210 start-up noise filtered" journal WARN "2 unexpected error lines" "(7 before the noise filter)"
expect_has "the hub re-enabling a port still shows" "$details" "disabled by hub (EMI?)"
expect_has "a real iwlwifi error still shows" "$details" "Microcode SW error"

reset
STUB_JOURNAL=$F/journal/errors-short-iso.txt
printf '# comment\n\n   \nNvPCR\n' >"$T/ignore"
JOURNAL_IGNORE=$T/ignore
check_journal
expect "blank pattern lines ignored" journal WARN "unexpected error lines"
expect_has "blank pattern: ACPI not hidden" "$details" "ACPI"

reset
STUB_JOURNAL=$F/journal/errors-short-iso.txt
printf 'NvPCR\n(unclosed\n' >"$T/ignore"
JOURNAL_IGNORE=$T/ignore
check_journal
expect "broken pattern" journal-filter WARN "invalid pattern"
expect "broken pattern, unfiltered" journal WARN "60 unexpected"

reset
JOURNAL_IGNORE=$T/no-such-file
STUB_JOURNAL=$F/journal/errors-short-iso.txt
check_journal
expect "built-in filter" journal WARN "2 unexpected error lines"

reset
STUB_CORES=$F/journal/coredumps.json
check_journal
expect "coredumps" coredumps WARN "Hyprland x2, xdg-desktop-portal-hyprland x1"

# ---- timers -------------------------------------------------------------------

reset
check_timers
expect "timers enabled" timers OK

reset
STUB_TIMER_STATES="btrfs-scrub@-.timer=disabled btrfs-scrub@mnt-data.timer=disabled kitchen-update.timer=not-found"
check_timers
expect "timers off" timers INFO "not enabled: btrfs-scrub@-.timer btrfs-scrub@mnt-data.timer; not installed: kitchen-update.timer"

# ---- settings -----------------------------------------------------------------

# Every default written out in checkup.conf must be the script's own default.
while IFS= read -r line; do
  key=${line%%=*}
  key=${key#\#}
  want=$(eval "printf '%s' ${line#*=}")
  expect_eq "checkup.conf default $key" "$want" "$(
    # shellcheck source=bin/kitchen-checkup
    source "$here/../bin/kitchen-checkup"
    printf '%s' "${!key}"
  )"
done < <(grep -E '^#[A-Z_]+=' "$here/../etc/kitchen-sink/checkup.conf")

# The daemon's shipped thermal.conf and the check-up agree on the NVMe levels.
if [[ -f $here/../etc/kitchen-sink/thermal.conf ]]; then
  for d in $THERMAL_NVME_DEFAULTS; do
    IFS=: read -r role w c l <<<"$d"
    i=0
    for level in WARN CRIT CLEAR; do
      want=$(sed -nE "s/^#?NVME_${role}_${level}=\"?([0-9]+)\"?.*/\1/p" "$here/../etc/kitchen-sink/thermal.conf" | tail -n 1)
      have=$(cut -d' ' -f$((i + 1)) <<<"$w $c $l")
      i=$((i + 1))
      [[ -z $want ]] || expect_eq "thermal.conf NVME_${role}_${level} = THERMAL_NVME_DEFAULTS" "$have" "$want"
    done
  done
fi

# The shipped noise filter and the built-in fallback hold the same patterns.
expect_eq "journal-ignore.regex = DEFAULT_IGNORE" \
  "$(grep -vE '^[[:space:]]*(#|$)' "$here/../etc/kitchen-sink/journal-ignore.regex")" "$DEFAULT_IGNORE"

reset
printf 'ROOT_WARN_GIB=99\n' >"$T/checkup.conf"
CONF=$T/checkup.conf
load_config
expect_eq "config applies" "$ROOT_WARN_GIB" 99
ROOT_WARN_GIB=40
if ((EUID == 0)); then
  chmod 0666 "$T/checkup.conf"
  printf 'ROOT_WARN_GIB=1\n' >"$T/checkup.conf"
  load_config
  expect "unsafe config ignored" config WARN "must be owned by root"
  expect_eq "unsafe config not applied" "$ROOT_WARN_GIB" 40
fi

# ---- the command line ---------------------------------------------------------

cli=$here/../bin/kitchen-checkup
out=$(bash "$cli" --help)
expect_eq "help exit" "$?" 0
expect_has "help text" "$out" "Usage: kitchen-checkup [--no-notify] [--quiet] [--json]"
out=$(bash "$cli" --bogus 2>&1)
expect_eq "bad option exit" "$?" 3
expect_has "bad option text" "$out" "unknown option --bogus"
if ((EUID != 0)); then
  out=$(bash "$cli" --no-notify 2>&1)
  expect_eq "non-root exit" "$?" 3
  expect_has "non-root text" "$out" "run as root"
fi

# ---- the whole run ------------------------------------------------------------

# main needs root; the container runs the tests as root.
if ((EUID == 0)); then
  cat >"$T/notify-stub" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >"$T/notify-args"
EOF
  chmod +x "$T/notify-stub"
  conf_for_main() {
    cat >"$T/checkup.conf" <<EOF
REPORT_DIR=$T/log
STATE_DIR=$T/state
CACHE_DIR=$T/cache
NOTIFY_CMD=$T/notify-stub
SB_ENGINE=$T/omarchy-secureboot
NVME_HELPER=$T/nvme-stub.py
UPDATE_STATUS=$T/status.json
UPDATE_LAST_SUCCESS=$T/last-success
UPDATE_GRANT=$T/etc/98-kitchen-update
JOURNAL_IGNORE=$here/../etc/kitchen-sink/journal-ignore.regex
EOF
    chmod 0644 "$T/checkup.conf"
    CONF=$T/checkup.conf
  }
  # main takes the time from the clock, so keep every age in range of "now".
  date() {
    if [[ $* == "+%s" ]]; then
      command date -d '2026-09-28T09:03:00-04:00' +%s
    else
      command date "$@"
    fi
  }

  reset
  conf_for_main
  STUB_QU="" STUB_CHECKUPDATES_RC=2 STUB_CHECKUPDATES=""
  STUB_TIMER_STATES=""
  STUB_SCRUB_root=$F/btrfs/scrub-finished.txt
  out=$(main --no-notify)
  rc=$?
  expect_eq "main healthy exit" "$rc" 0
  expect_has "main healthy output" "$out" "Result: OK"
  expect_eq "main report" "$(readlink "$T/log/latest.txt")" 2026-09-28.txt
  expect_eq "main json status" "$(jq -r .status "$T/log/latest.json")" OK
  expect_eq "main json checks" "$(jq -r '.checks[0] | "\(.level) \(.check)"' "$T/log/latest.json")" "OK secureboot"
  expect_eq "main report mode" "$(stat -c %a "$T/log/2026-09-28.txt")" 644
  expect_has "main last-run" "$(cat "$T/state/last-run")" 2026-09-28T09:03:00
  expect_eq "main no toast with --no-notify" "$([[ -e $T/notify-args ]] && echo sent)" ""

  # A FAIL day under systemd: priority prefixes, a critical toast, exit 2
  reset
  conf_for_main
  echo 1 >"$T/sb-rc"
  touch "$T/etc/98-kitchen-update"
  STUB_NTP=no
  out=$(
    journal_stdout() { return 0; }
    main
  )
  rc=$?
  expect_eq "main fail exit" "$rc" 2
  expect_has "main fail journal prefix" "$out" "<3>FAIL secureboot: 'omarchy secureboot status' needs attention"
  expect_has "main warn journal prefix" "$out" "<4>WARN "
  expect_has "main info journal prefix" "$out" "<6>OK units:"
  expect_has "main result line" "$out" "<3>Result: FAIL (2 fail"
  sent=$(cat "$T/notify-args")
  expect_has "toast urgency" "$sent" $'--urgency\ncritical'
  expect_has "toast title" "$sent" "kitchen-sink check-up: 2 problems, 1 warning"
  expect_has "toast body order" "$sent" $'--body\nsecureboot: '
  expect_has "toast opens the report" "$sent" $'--open\n'"$T/log/2026-09-28.txt"
  expect_has "toast waits for the session" "$sent" $'--wait\n180'
  expect_has "toast app name" "$sent" $'--app-name\nkitchen-sink-checkup'
  expect_has "toast goes to the configured user" "$sent" $'--user\nkevinwyckoff'
  expect_has "report details" "$(cat "$T/log/latest.txt")" "== omarchy secureboot status"
  # TEST_KEEP=dir keeps this day's report and JSON for a look.
  if [[ -n ${TEST_KEEP:-} ]]; then
    cp "$T/log/2026-09-28.txt" "$TEST_KEEP/report-fail-day.txt"
    cp "$T/log/latest.json" "$TEST_KEEP/report-fail-day.json"
    printf '%s\n' "$out" >"$TEST_KEEP/journal-fail-day.txt"
    cp "$T/notify-args" "$TEST_KEEP/notify-args-fail-day.txt"
  fi

  # --quiet prints only problems; --json prints the document
  reset
  conf_for_main
  out=$(main --no-notify --quiet)
  rc=$?
  expect_eq "main quiet exit (held back and pending are INFO)" "$rc" 0
  expect_eq "main quiet prints no OK lines" "$(grep -c '^OK' <<<"$out")" 0

  reset
  conf_for_main
  STUB_NTP=no
  out=$(main --no-notify --json)
  rc=$?
  expect_eq "main json exit" "$rc" 1
  expect_eq "main json stdout" "$(jq -r '.counts.warn' <<<"$out")" 1
  expect_eq "main json warn check" "$(jq -r '.checks[] | select(.level == "WARN") | .check' <<<"$out")" time

  # An OK day sends a low toast with a one-line summary
  reset
  conf_for_main
  STUB_QU="" STUB_CHECKUPDATES_RC=2 STUB_CHECKUPDATES=""
  out=$(main)
  sent=$(cat "$T/notify-args")
  expect_has "ok toast urgency" "$sent" $'--urgency\nlow'
  expect_has "ok toast body" "$sent" "checks passed; no updates pending"

  # Old reports go after KEEP_REPORTS_DAYS
  reset
  conf_for_main
  mkdir -p "$T/log"
  # find -mtime counts from the real clock, not the pinned one
  touch -d '100 days ago' "$T/log/2026-06-01.txt"
  touch -d '60 days ago' "$T/log/2026-08-01.txt"
  touch -d '100 days ago' "$T/log/notes.txt"
  out=$(main --no-notify)
  expect_eq "old report pruned" "$([[ -e $T/log/2026-06-01.txt ]] && echo kept)" ""
  expect_eq "recent report kept" "$([[ -e $T/log/2026-08-01.txt ]] && echo kept)" kept
  expect_eq "other files kept" "$([[ -e $T/log/notes.txt ]] && echo kept)" kept

  # A check that breaks exits 3, so the unit shows it
  reset
  conf_for_main
  # shellcheck disable=SC2154 # unset on purpose: set -u must abort the run
  check_time() { echo "$undefined_variable"; }
  # exec: the EXIT trap writes after main's own redirections are gone
  out=$(
    exec 2>&1
    main --no-notify
  )
  rc=$?
  expect_eq "main crash exit" "$rc" 3
  expect_has "main crash message" "$out" "stopped before finishing"
  unset -f date
else
  echo "test-checkup: not root, so the end-to-end main tests are skipped" >&2
fi

finish test-checkup
