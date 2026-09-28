#!/bin/bash

# install.sh: install kitchen-sink's daily check-up and nightly updater.
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
#   - installs the four units to /etc/systemd/system and the sysusers and
#     tmpfiles snippets to /etc (root:root 0644)
#   - installs /etc/kitchen-sink/{checkup.conf,update.conf,journal-ignore.regex}
#     (root:root 0644). A file you have changed is kept, and the shipped one is
#     put next to it as <name>.new for you to merge. A file you never changed
#     is updated in place: /var/lib/kitchen-sink/configs.sha256 remembers what
#     was shipped, the way pacman tells an edited config from an old one.
#   - creates the empty kitchen-update group and /run/kitchen-update
#   - enables and starts the daily check-up timer and the monthly btrfs scrub
#     timers for / and /mnt/data
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
LIBS=(notify safe-to-update preflight postflight nvme-health.py evwatch.py news-check.py)
CONFIGS=(checkup.conf update.conf journal-ignore.regex)
UNITS=(kitchen-checkup.service kitchen-checkup.timer kitchen-update.service kitchen-update.timer)
SYSUSERS=kitchen-update.conf
TMPFILES=kitchen-update.conf
GRANT_GROUP=kitchen-update
GRANT_FILE=/etc/sudoers.d/98-kitchen-update

# The btrfs filesystems that get btrfs-progs' own monthly scrub timer.
SCRUB_MOUNTS=(/ /mnt/data)

# Each command the check-up or the updater calls that is not in base, and the
# package it comes from. All of them are on kitchen-sink already.
REQUIRED=(jq:jq python3:python checkupdates:pacman-contrib pacdiff:pacman-contrib
  pacman-conf:pacman btrfs:btrfs-progs sudo:sudo visudo:sudo setpriv:util-linux
  runuser:util-linux flock:util-linux busctl:systemd coredumpctl:systemd
  systemd-escape:systemd systemd-sysusers:systemd systemd-tmpfiles:systemd
  systemd-inhibit:systemd objcopy:binutils modinfo:kmod cmp:diffutils)

warnings=()
merge=()
changes=0

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

Installs kitchen-sink's daily check-up and nightly updater from this directory.
Safe to run again. Leaves kitchen-update.timer as it is (off on a first install).
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
    return 0
  fi
  install -o root -g root -m "$mode" -T "$src" "$dest"
  say "$what" "$dest ($mode)"
  changes=$((changes + 1))
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
put_config() {
  local src=$1 dest=$2 name=${2##*/}
  if [[ ! -e $dest ]]; then
    install -o root -g root -m 0644 -T "$src" "$dest"
    say installed "$dest (0644)"
    changes=$((changes + 1))
  elif ! cmp -s "$src" "$dest" && [[ $(sha "$dest") == "$(shipped_sum "$name")" ]]; then
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
  else
    install -o root -g root -m 0644 -T "$src" "$dest.new"
    say kept "$dest (yours differs; the shipped one is now $dest.new)"
    merge+=("$dest")
    changes=$((changes + 1))
  fi
  # Only a config that matches the shipped file is recorded: yours keeps the
  # checksum of the version you started from until you merge.
  ! cmp -s "$src" "$dest" || record_sum "$name" "$dest"
  secure_config "$dest"
}

scrub_timer() { echo "btrfs-scrub@$(systemd-escape -p "$1").timer"; }

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
  say verified "the four units (systemd-analyze verify)"
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

# ---- summary ----------------------------------------------------------------------

echo
if ((${#merge[@]})); then
  echo "Your changed settings were kept. Merge the shipped versions by hand:"
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
if ((!updater_on)); then
  cat <<'NEXT'
  sudo kitchen-update --dry-run --quiet-secs 60     # every updater gate; changes nothing
  sudo kitchen-update --grant-test                  # the sudo grant, both ways, then revoked
Then one supervised run (README.md), and only after it:
  sudo systemctl enable --now kitchen-update.timer
NEXT
fi
