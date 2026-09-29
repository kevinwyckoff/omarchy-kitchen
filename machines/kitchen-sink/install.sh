#!/bin/bash

# install.sh: install kitchen-sink's daily check-up, nightly updater and
# thermal event daemon.
#
# Run it as root on kitchen-sink, from a copy of this directory:
#
#   sudo bash /tmp/kitchen-sink/install.sh
#
# README.md shows how to copy the directory over from Marvin. Running it again
# is safe: it changes only what differs and says what it did.
#
# What it does:
#   - installs kitchen-checkup and kitchen-update to /usr/local/sbin and their
#     helpers to /usr/local/lib/kitchen-sink (root:root 0755)
#   - installs the units to /etc/systemd/system and the sysusers and
#     tmpfiles snippets to /etc (root:root 0644)
#   - installs /etc/kitchen-sink/{checkup.conf,update.conf,journal-ignore.regex,
#     thermal.conf} (root:root 0644). A file you have changed is kept, and the
#     shipped one is put next to it as <name>.new for you to merge. A file you
#     never changed is updated in place: /var/lib/kitchen-sink/configs.sha256
#     remembers what was shipped, the way pacman tells an edited config from an
#     old one.
#   - creates the empty kitchen-update group and /run/kitchen-update
#   - enables and starts the daily check-up timer and the monthly btrfs scrub
#     timers for / and /mnt/data
#   - enables and starts kitchen-thermal.service, the thermal event daemon
#     (restarting it when its files changed), and puts the sample hooks in the
#     desktop user's ~/.config/omarchy/hooks/thermal.d, as that user
#
# The patched nct6775 the daemon needs for Super I/O events comes in its own
# package, nct6775-notify-dkms (pkg/nct6775-notify-dkms), installed with
# pacman -U. This only says whether it is there and loaded, and what to run.
#
# It does NOT enable kitchen-update.timer. The nightly updater stays off until
# its dry run, its grant test and one supervised run have passed on this
# machine (README.md, "Turning on the nightly updater"). If the timer is
# already enabled, it stays enabled.

set -euo pipefail

SRC=$(dirname "$(readlink -f "$0")")

SBIN_DIR=/usr/local/sbin
LIB_DIR=/usr/local/lib/kitchen-sink
CONF_DIR=/etc/kitchen-sink
UNIT_DIR=/etc/systemd/system
# The checksum of each config as this script last installed it.
SUMS=/var/lib/kitchen-sink/configs.sha256

BINS=(kitchen-checkup kitchen-update)
LIBS=(notify safe-to-update preflight postflight nvme-health.py evwatch.py news-check.py kitchen-thermald.py)
CONFIGS=(checkup.conf update.conf journal-ignore.regex thermal.conf)
UNITS=(kitchen-checkup.service kitchen-checkup.timer kitchen-update.service kitchen-update.timer kitchen-thermal.service)
SYSUSERS=kitchen-update.conf
TMPFILES=kitchen-update.conf
GRANT_GROUP=kitchen-update
GRANT_FILE=/etc/sudoers.d/98-kitchen-update

# The btrfs filesystems that get btrfs-progs' own monthly scrub timer.
SCRUB_MOUNTS=(/ /mnt/data)

# The thermal event daemon: its unit, the files whose change means a restart,
# the user whose omarchy-hook runs its hooks (as the daemon picks them:
# thermal.conf's HOOK_USER, else checkup.conf's DESKTOP_USER, else this), and
# the package with the patched nct6775.
THERMAL_UNIT=kitchen-thermal.service
THERMAL_FILES=(kitchen-thermald.py thermal.conf kitchen-thermal.service)
DESKTOP_USER=kevinwyckoff
THERMAL_DKMS=nct6775-notify-dkms
NCT_SYSFS=/sys/module/nct6775_core

# Each command the check-up or the updater calls that is not in base, and the
# package it comes from. All of them are on kitchen-sink already.
REQUIRED=(jq:jq python3:python checkupdates:pacman-contrib pacdiff:pacman-contrib
  pacman-conf:pacman btrfs:btrfs-progs sudo:sudo visudo:sudo setpriv:util-linux
  runuser:util-linux flock:util-linux busctl:systemd coredumpctl:systemd
  systemd-escape:systemd systemd-sysusers:systemd systemd-tmpfiles:systemd
  systemd-inhibit:systemd objcopy:binutils modinfo:kmod cmp:diffutils)

warnings=()
merge=()
next=()
changes=0
# Set by put and put_config when they change the file in use, so the thermal
# daemon is restarted onto its new files.
put_changed=0 thermal_changed=0

say() { printf '  %-13s %s\n' "$1" "$2"; }

warn() {
  warnings+=("$*")
  printf '  %-13s %s\n' "WARNING" "$*"
}

die() {
  echo "install.sh: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: sudo bash install.sh

Installs kitchen-sink's daily check-up, nightly updater and thermal event
daemon from this directory. Safe to run again. Leaves kitchen-update.timer as
it is (off on a first install).
USAGE
}

# A unit that is doing its work right now; its files must not change under it.
unit_busy() {
  case $(systemctl show -P ActiveState "$1" 2>/dev/null) in
  active | activating | deactivating | reloading) return 0 ;;
  *) return 1 ;;
  esac
}

# put SOURCE DEST MODE: install SOURCE as DEST, owned by root with MODE, when
# it differs in content, owner or mode. install(1) unlinks DEST first, so a
# script that is running keeps reading its old copy.
put() {
  local src=$1 dest=$2 mode=$3 what
  if [[ ! -e $dest ]]; then
    what=installed
  elif ! cmp -s "$src" "$dest"; then
    what=updated
  elif [[ $(stat -c '%u:%g %a' "$dest") != "0:0 ${mode#0}" ]]; then
    what="fixed mode"
  else
    say unchanged "$dest"
    put_changed=0
    return 0
  fi
  install -o root -g root -m "$mode" -T "$src" "$dest"
  say "$what" "$dest ($mode)"
  changes=$((changes + 1))
  put_changed=1
}

# A shipped file of the thermal daemon's: its change needs a restart.
note_thermal() { # name
  if ((put_changed)) && [[ " ${THERMAL_FILES[*]} " == *" $1 "* ]]; then
    thermal_changed=1
  fi
}

# Both scripts source their config as root, and skip one that is not owned by
# root or that group or others can write. Make sure ours qualify.
secure_config() {
  local f=$1 owner mode
  read -r owner mode < <(stat -c '%u %a' "$f")
  if ((owner != 0 || 8#$mode & 8#022)); then
    chown root:root "$f"
    chmod go-w "$f"
    say "fixed mode" "$f (was uid $owner, mode $mode; the scripts ignore a config others can change)"
    changes=$((changes + 1))
  fi
}

sha() { sha256sum <"$1" | cut -d' ' -f1; }

# The checksum recorded for a config name, and recording a new one.
shipped_sum() { awk -v n="$1" '$2 == n { print $1 }' "$SUMS" 2>/dev/null; }
record_sum() { # name file
  local sum
  sum=$(sha "$2")
  [[ $(shipped_sum "$1") != "$sum" ]] || return 0
  install -d -o root -g root -m 0755 "${SUMS%/*}"
  { awk -v n="$1" '$2 != n' "$SUMS" 2>/dev/null; echo "$sum  $1"; } >"$SUMS.new" && mv -f "$SUMS.new" "$SUMS"
}

# put_config SOURCE DEST: a settings file. Yours wins: when you have changed
# DEST, the shipped one goes to DEST.new instead. A DEST that is still exactly
# what an earlier install shipped is yours in name only, so it is updated.
# Like pacman's .pacnew, each shipped version is offered once: after you merge
# DEST.new and delete it, yours is kept quietly until a newer one ships.
put_config() {
  local src=$1 dest=$2 name=${2##*/}
  put_changed=0
  if [[ ! -e $dest ]]; then
    put_changed=1
    install -o root -g root -m 0644 -T "$src" "$dest"
    say installed "$dest (0644)"
    changes=$((changes + 1))
  elif ! cmp -s "$src" "$dest" && [[ $(sha "$dest") == "$(shipped_sum "$name")" ]]; then
    put_changed=1
    install -o root -g root -m 0644 -T "$src" "$dest"
    say updated "$dest (0644; you had not changed it)"
    changes=$((changes + 1))
    if [[ -e $dest.new ]]; then
      rm -f -- "$dest.new"
      say removed "$dest.new"
    fi
  elif cmp -s "$src" "$dest"; then
    say unchanged "$dest"
    if [[ -e $dest.new ]]; then
      rm -f -- "$dest.new"
      say removed "$dest.new (yours matches the shipped file now)"
      changes=$((changes + 1))
    fi
  elif [[ -e $dest.new ]] && cmp -s "$src" "$dest.new"; then
    say kept "$dest (yours differs; $dest.new still waits to be merged)"
    merge+=("$dest")
  elif [[ $(sha "$src") == "$(shipped_sum "$name")" ]]; then
    say kept "$dest (yours; nothing newer shipped since you were offered it)"
  else
    install -o root -g root -m 0644 -T "$src" "$dest.new"
    say kept "$dest (yours differs; the shipped one is now $dest.new)"
    merge+=("$dest")
    changes=$((changes + 1))
  fi
  # The shipped version is recorded whether it went in place or to .new: it is
  # what an unedited DEST would be, and what you have been offered.
  record_sum "$name" "$src"
  secure_config "$dest"
}

scrub_timer() { echo "btrfs-scrub@$(systemd-escape -p "$1").timer"; }

# One KEY=value from a settings file, without sourcing it: the last
# uncommented assignment, its trailing comment and quotes dropped.
conf_value() { # file key
  local v
  v=$(sed -nE "s/^[[:space:]]*$2=//p" "$1" 2>/dev/null | tail -n 1)
  v=${v%%[[:space:]]#*}
  v=${v%"${v##*[![:space:]]}"}
  if [[ $v =~ ^\"(.*)\"$ || $v =~ ^\'(.*)\'$ ]]; then
    v=${BASH_REMATCH[1]}
  fi
  printf '%s' "$v"
}

# enable_service UNIT RESTART: enable it for every boot and make sure it runs;
# with RESTART=1 a running one is restarted onto its new files. A daemon that
# will not start is a warning, not a failed install: the check-up reports it.
enable_service() {
  local s=$1 restart=$2 state
  if [[ $(systemctl is-enabled "$s" 2>/dev/null) != "enabled" ]]; then
    systemctl enable --quiet "$s"
    say enabled "$s"
    changes=$((changes + 1))
  fi
  if ! systemctl is-active --quiet "$s"; then
    systemctl start "$s" 2>/dev/null || true
    say started "$s"
    changes=$((changes + 1))
  elif ((restart)); then
    systemctl restart "$s" 2>/dev/null || true
    say restarted "$s (its files changed)"
  else
    say unchanged "$s (running)"
    return 0
  fi
  # Give a daemon that dies at once the moment to do so.
  sleep 2
  state=$(systemctl show -P ActiveState "$s" 2>/dev/null)
  if [[ $state != "active" ]]; then
    warn "$s is $state after starting: see journalctl -u ${s%.service} -b"
  fi
}

# as_user USER CMD...: run CMD with the user's ids and groups. setpriv, not
# runuser: no PAM session, so it never starts the user's systemd manager.
as_user() {
  local user=$1
  shift
  setpriv --reuid="$(id -u "$user")" --regid="$(id -g "$user")" --init-groups -- "$@"
}

# install_hook SOURCE USER HOME: a sample hook into the user's thermal.d. It is
# written by the user, never by root, so nothing in their home can redirect it.
install_hook() {
  local src=$1 user=$2 dir=$3/.config/omarchy/hooks/thermal.d dest
  dest=$dir/${src##*/}
  if [[ -f $dest ]] && cmp -s "$src" "$dest"; then
    say unchanged "$dest"
    return 0
  fi
  # shellcheck disable=SC2016 # $1 is the inner shell's, on purpose
  if as_user "$user" mkdir -p "$dir" 2>/dev/null &&
    as_user "$user" sh -c 'cat >"$1.tmp" && chmod 0644 "$1.tmp" && mv -f "$1.tmp" "$1"' _ "$dest" <"$src" 2>/dev/null; then
    say installed "$dest ($user, 0644)"
    changes=$((changes + 1))
  else
    warn "$user cannot write $dir, so the sample hook ${src##*/} was not installed (is ~/.config/omarchy theirs?)"
  fi
}

# enable_timer UNIT: enable it for every boot and start it now.
enable_timer() {
  local t=$1 next
  if [[ $(systemctl is-enabled "$t" 2>/dev/null) == "enabled" ]] && systemctl is-active --quiet "$t"; then
    say unchanged "$t (enabled)"
  else
    systemctl enable --now --quiet "$t"
    say enabled "$t"
    changes=$((changes + 1))
  fi
  next=$(systemctl show -P NextElapseUSecRealtime "$t" 2>/dev/null)
  [[ -z $next || $next == "n/a" ]] || say "" "next run: $next"
}

# ---- checks before anything changes ---------------------------------------------

case ${1:-} in
"") ;;
-h | --help)
  usage
  exit 0
  ;;
*)
  usage >&2
  exit 2
  ;;
esac

((EUID == 0)) || die "run as root: sudo bash $0"

for f in "${BINS[@]/#/bin/}" "${LIBS[@]/#/lib/}" "${CONFIGS[@]/#/etc/kitchen-sink/}" "${UNITS[@]/#/systemd/}" \
  "etc/sysusers.d/$SYSUSERS" "etc/tmpfiles.d/$TMPFILES"; do
  [[ -f $SRC/$f ]] || die "$SRC/$f is missing; copy the whole machines/kitchen-sink directory"
done
HOOKS=("$SRC"/share/thermal.d/*.sample)
[[ -f ${HOOKS[0]} ]] || die "$SRC/share/thermal.d has no sample hooks; copy the whole machines/kitchen-sink directory"

missing=()
for entry in "${REQUIRED[@]}"; do
  command -v "${entry%%:*}" >/dev/null || missing+=("${entry%%:*} (package ${entry#*:})")
done
((${#missing[@]} == 0)) || die "missing commands: ${missing[*]}"

for unit in kitchen-update.service kitchen-checkup.service; do
  if unit_busy "$unit"; then
    die "$unit is running right now; wait for it to finish (journalctl -fu ${unit%.service}) and run this again"
  fi
done

echo "kitchen-sink: installing from $SRC"
# From here on a failure leaves a partial install; running again completes it.
stopped_part_way() {
  local rc=$?
  ((rc == 0)) || echo "install.sh: stopped part way (exit $rc). Fix the error above and run it again; it redoes only what is missing." >&2
}
trap stopped_part_way EXIT

# ---- programs ---------------------------------------------------------------------

install -d -o root -g root -m 0755 "$SBIN_DIR" "$LIB_DIR"
for f in "${BINS[@]}"; do
  put "$SRC/bin/$f" "$SBIN_DIR/$f" 0755
done
for f in "${LIBS[@]}"; do
  put "$SRC/lib/$f" "$LIB_DIR/$f" 0755
  note_thermal "$f"
done
# The directory is ours alone: a helper this version no longer ships goes.
for f in "$LIB_DIR"/* "$LIB_DIR"/.[!.]*; do
  [[ -e $f ]] || continue
  if [[ " ${LIBS[*]} " != *" ${f##*/} "* ]]; then
    rm -rf -- "$f"
    say removed "$f (no longer shipped)"
    changes=$((changes + 1))
  fi
done

# ---- settings ---------------------------------------------------------------------

install -d -o root -g root -m 0755 "$CONF_DIR"
for f in "${CONFIGS[@]}"; do
  put_config "$SRC/etc/kitchen-sink/$f" "$CONF_DIR/$f"
  note_thermal "$f"
done

# ---- the updater's group and runtime directory ----------------------------------

install -d -o root -g root -m 0755 /etc/sysusers.d /etc/tmpfiles.d
put "$SRC/etc/sysusers.d/$SYSUSERS" "/etc/sysusers.d/$SYSUSERS" 0644
put "$SRC/etc/tmpfiles.d/$TMPFILES" "/etc/tmpfiles.d/$TMPFILES" 0644
created=""
getent group "$GRANT_GROUP" >/dev/null || created="created, "
out=$(systemd-sysusers "/etc/sysusers.d/$SYSUSERS" 2>&1) || die "systemd-sysusers failed: $out"
# --create only: the r! lines that remove a leftover grant act at boot alone.
out=$(systemd-tmpfiles --create "/etc/tmpfiles.d/$TMPFILES" 2>&1) || die "systemd-tmpfiles failed: $out"

IFS=: read -r _ _ gid members < <(getent group "$GRANT_GROUP") || die "systemd-sysusers did not create the $GRANT_GROUP group"
[[ -z $created ]] || changes=$((changes + 1))
primary=$(getent passwd | awk -F: -v g="$gid" '$4 == g { print $1 }' | paste -sd' ' -)
if [[ -n $members || -n $primary ]]; then
  warn "group $GRANT_GROUP (gid $gid) has members (${members}${primary:+ ${primary} by primary group}): remove them, or the updater refuses to grant sudo"
else
  say group "$GRANT_GROUP (${created}gid $gid), no members, as it must be"
fi
[[ -d /run/kitchen-update ]] && say directory "/run/kitchen-update (for the one-shot force-idle flag)"

# ---- units and timers -------------------------------------------------------------

install -d -o root -g root -m 0755 "$UNIT_DIR"
for f in "${UNITS[@]}"; do
  put "$SRC/systemd/$f" "$UNIT_DIR/$f" 0644
  note_thermal "$f"
done
systemctl daemon-reload
say reloaded "systemd (daemon-reload)"

verify=$(cd / && systemd-analyze verify "${UNITS[@]/#/$UNIT_DIR/}" 2>&1) || true
if [[ -n $verify ]]; then
  warn "systemd-analyze verify has remarks on the units:"
  while IFS= read -r line; do
    say "" "  $line"
  done <<<"$verify"
else
  say verified "the ${#UNITS[@]} units (systemd-analyze verify)"
fi

enable_timer kitchen-checkup.timer

# btrfs-progs ships btrfs-scrub@.timer (monthly, a random week, idle I/O). The
# instance name is the escaped mount path; the check-up watches the same names.
expected_timers=$(sed -n 's/^EXPECT_TIMERS="\(.*\)"$/\1/p' "$SRC/bin/kitchen-checkup")
if systemctl cat btrfs-scrub@.timer >/dev/null 2>&1; then
  for m in "${SCRUB_MOUNTS[@]}"; do
    t=$(scrub_timer "$m")
    if [[ " $expected_timers " != *" $t "* ]]; then
      warn "$t (for $m) is not among the timers the check-up watches ($expected_timers)"
    fi
    if [[ $(findmnt -no FSTYPE --mountpoint "$m" 2>/dev/null) != "btrfs" ]]; then
      warn "$m is not a mounted btrfs filesystem now; its scrub is skipped until it is (ConditionPathIsMountPoint)"
    fi
    enable_timer "$t"
  done
else
  warn "btrfs-scrub@.timer is missing (btrfs-progs); no monthly scrubs enabled"
fi

# The nightly updater: installed, but only switched on by hand once proven here.
updater_on=0
if [[ $(systemctl is-enabled kitchen-update.timer 2>/dev/null) == "enabled" ]]; then
  updater_on=1
  say "left on" "kitchen-update.timer (it was already enabled)"
else
  say "left off" "kitchen-update.timer: turn it on after the dry run, the grant test and one supervised run (README.md)"
fi

if [[ -e $GRANT_FILE ]]; then
  warn "$GRANT_FILE exists while no update runs: remove it with sudo kitchen-update --revoke"
fi
# The updater's Secure Boot gates and postflight read sbctl verify.
if [[ -e /var/lib/omarchy-secureboot/enabled ]] && ! command -v sbctl >/dev/null; then
  warn "Secure Boot is managed here but sbctl is missing: install it before the updater's dry run"
fi

# ---- thermal events ----------------------------------------------------------------

# The daemon runs from now on; a reinstall that changed it restarts it.
enable_service "$THERMAL_UNIT" "$thermal_changed"

# Its sample hooks, for the user whose omarchy-hook runs them. omarchy-hook
# skips *.sample; the user copies one without the suffix to use it.
hook_user=$(conf_value "$CONF_DIR/thermal.conf" HOOK_USER)
[[ -n $hook_user ]] || hook_user=$(conf_value "$CONF_DIR/checkup.conf" DESKTOP_USER)
hook_user=${hook_user:-$DESKTOP_USER}
if hook_home=$(getent passwd "$hook_user" | cut -d: -f6) && [[ -d $hook_home ]]; then
  for f in "${HOOKS[@]}"; do
    install_hook "$f" "$hook_user" "$hook_home"
  done
else
  warn "no home for the hook user $hook_user: the sample thermal hooks were not installed"
fi

# The patched nct6775 comes in its own package; say where it stands.
kernel=$(uname -r)
if [[ -r $NCT_SYSFS/parameters/notify_interval ]]; then
  say driver "the patched nct6775 is loaded (notify_interval=$(<"$NCT_SYSFS/parameters/notify_interval") ms)"
elif ! pkg=$(pacman -Q "$THERMAL_DKMS" 2>/dev/null); then
  say driver "$THERMAL_DKMS is not installed: the daemon polls the Super I/O every 10 s instead of getting events"
  next+=("# the patched nct6775 for Super I/O events (README.md, Thermal events): build pkg/nct6775-notify-dkms, then"
    "sudo pacman -U nct6775-notify-dkms-*.pkg.tar.zst"
    "sudo modprobe -r nct6775 nct6775_core && sudo modprobe nct6775   # fans stay under SmartFan meanwhile")
elif modinfo -k "$kernel" -F filename nct6775_core 2>/dev/null | grep -q '/updates/dkms/'; then
  say driver "$pkg is built for $kernel, but the in-tree nct6775 is still loaded"
  next+=("sudo modprobe -r nct6775 nct6775_core && sudo modprobe nct6775   # switch to the patched nct6775; fans stay under SmartFan")
else
  warn "$pkg has no module for $kernel (outside its kernel range, or its build failed: dkms status): Super I/O events stay off"
fi

# ---- summary ----------------------------------------------------------------------

echo
if ((${#merge[@]})); then
  echo "Your changed settings were kept. Merge the shipped versions by hand, then delete each .new:"
  for f in "${merge[@]}"; do
    echo "  diff -u $f $f.new"
  done
  echo
fi

if ((changes == 0)); then
  echo "Already installed: nothing changed."
else
  echo "Installed: $changes change(s)."
fi
((${#warnings[@]} == 0)) || echo "${#warnings[@]} warning(s) above."
echo "Next:"
echo "  sudo kitchen-checkup --no-notify                  # a check-up now, printed here"
echo "  sudo systemctl start kitchen-checkup.service      # the same under systemd, with the toast"
for line in "${next[@]}"; do
  echo "  $line"
done
if ((!updater_on)); then
  cat <<'NEXT'
  sudo kitchen-update --dry-run --quiet-secs 60     # every updater gate; changes nothing
  sudo kitchen-update --grant-test                  # the sudo grant, both ways, then revoked
Then one supervised run (README.md), and only after it:
  sudo systemctl enable --now kitchen-update.timer
NEXT
fi
