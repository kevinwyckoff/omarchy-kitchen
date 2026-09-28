#!/bin/bash

# uninstall.sh: remove kitchen-sink's daily check-up and nightly updater.
#
#   sudo bash uninstall.sh [--purge] [--disable-scrubs]
#
#   --purge           also delete the reports, logs and state:
#                     /var/log/kitchen-{checkup,update} and /var/lib/kitchen-{checkup,update}
#   --disable-scrubs  also turn off the monthly btrfs scrubs of / and /mnt/data.
#                     Those timers come with btrfs-progs and are worth keeping
#                     without the rest, so they stay on by default.
#
# It turns the timers off, revokes any sudo grant and proves it gone, then
# removes every file install.sh put in place and the kitchen-update group.
# Running it again is safe.
#
# It keeps the IgnorePkg pin in /etc/pacman.conf and the pre-refresh-pacman hook
# (~/.config/omarchy/hooks/pre-refresh-pacman.d/10-kitchen-pin): they protect
# manual updates too, for as long as the kitchen build is installed.

set -euo pipefail

SBIN_DIR=/usr/local/sbin
LIB_DIR=/usr/local/lib/kitchen-sink
CONF_DIR=/etc/kitchen-sink
UNIT_DIR=/etc/systemd/system
GRANT_GROUP=kitchen-update
GRANT_FILE=/etc/sudoers.d/98-kitchen-update
SCRUB_MOUNTS=(/ /mnt/data)

purge=0
scrubs=0
removed=0

say() { printf '  %-13s %s\n' "$1" "$2"; }

die() {
  echo "uninstall.sh: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: sudo bash uninstall.sh [--purge] [--disable-scrubs]
  --purge           also delete the reports, logs and state in /var/log and /var/lib
  --disable-scrubs  also turn off the monthly btrfs scrub timers (kept by default)
USAGE
}

# remove PATH...: delete what exists, and say so.
remove() {
  local p
  for p in "$@"; do
    [[ -e $p || -L $p ]] || continue
    rm -rf -- "$p"
    say removed "$p"
    removed=$((removed + 1))
  done
}

unit_known() { [[ $(systemctl show -P LoadState "$1" 2>/dev/null) == "loaded" ]]; }

unit_busy() {
  case $(systemctl show -P ActiveState "$1" 2>/dev/null) in
  active | activating | deactivating | reloading) return 0 ;;
  *) return 1 ;;
  esac
}

# disable_timer UNIT: stop it and take it out of every boot.
disable_timer() {
  local t=$1
  unit_known "$t" || return 0
  if [[ $(systemctl is-enabled "$t" 2>/dev/null) == "enabled" ]] || systemctl is-active --quiet "$t"; then
    systemctl disable --now --quiet "$t"
    say disabled "$t"
    removed=$((removed + 1))
  fi
}

for arg in "$@"; do
  case $arg in
  --purge) purge=1 ;;
  --disable-scrubs) scrubs=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
done

((EUID == 0)) || die "run as root: sudo bash $0"

# Uninstalling under a running update would pull its scripts away mid-run.
if unit_busy kitchen-update.service; then
  die "a nightly update is running now. Wait for it (journalctl -fu kitchen-update), or stop it with 'sudo systemctl stop kitchen-update.service', then run this again"
fi

echo "kitchen-sink: uninstalling the check-up and the nightly updater"

# ---- timers first, so nothing starts while the files go -------------------------

disable_timer kitchen-update.timer
disable_timer kitchen-checkup.timer
if unit_busy kitchen-checkup.service; then
  systemctl stop kitchen-checkup.service
  say stopped kitchen-checkup.service
fi

# ---- the sudo grant ---------------------------------------------------------------

# kitchen-update --revoke removes the rule and proves the grouped sudo -n is
# refused again; if it finds a grant, it also records the night as FAILED and
# toasts, since a grant should never outlive its run. The plain rm is the
# backstop for a half-installed updater.
if [[ -x $SBIN_DIR/kitchen-update ]]; then
  if out=$("$SBIN_DIR/kitchen-update" --revoke 2>&1); then
    rc=0
  else
    rc=$?
  fi
  # Its lines are "TAG  stage: text"; show the text.
  while read -r _ line; do
    [[ -z $line ]] || say revoke "${line#revoke: }"
  done <<<"$out"
  ((rc == 0)) || say revoke "kitchen-update --revoke exited $rc; removing the rule directly"
fi
remove "$GRANT_FILE" /etc/sudoers.d/.kitchen-update.*
[[ ! -e $GRANT_FILE ]] || die "$GRANT_FILE is still there; remove it by hand before anything else"
say "no grant" "$GRANT_FILE is gone"

# ---- units ------------------------------------------------------------------------

for unit in kitchen-update.service kitchen-checkup.service; do
  systemctl reset-failed "$unit" 2>/dev/null || true
done
remove "$UNIT_DIR"/kitchen-{update,checkup}.{service,timer}
# An enable link left behind by a unit file removed by hand.
remove "$UNIT_DIR"/timers.target.wants/kitchen-{update,checkup}.timer
systemctl daemon-reload
say reloaded "systemd (daemon-reload)"

# ---- programs, settings, group ------------------------------------------------------

remove "$SBIN_DIR/kitchen-update" "$SBIN_DIR/kitchen-checkup" "$LIB_DIR" "$CONF_DIR"
remove /etc/sysusers.d/kitchen-update.conf /etc/tmpfiles.d/kitchen-update.conf
remove /run/kitchen-update /run/kitchen-update.lock
# checkupdates' private copy of the sync databases; rebuilt on demand.
remove /var/cache/kitchen-checkup
# install.sh's record of the configs it shipped.
remove /var/lib/kitchen-sink

if getent group "$GRANT_GROUP" >/dev/null; then
  if groupdel "$GRANT_GROUP"; then
    say removed "group $GRANT_GROUP"
    removed=$((removed + 1))
  else
    say kept "group $GRANT_GROUP: groupdel failed (is it someone's primary group?)"
  fi
fi

# ---- optional -----------------------------------------------------------------------

if ((scrubs)); then
  for m in "${SCRUB_MOUNTS[@]}"; do
    disable_timer "btrfs-scrub@$(systemd-escape -p "$m").timer"
  done
fi

if ((purge)); then
  remove /var/lib/kitchen-update /var/lib/kitchen-checkup /var/log/kitchen-update /var/log/kitchen-checkup
fi

# ---- what stays -------------------------------------------------------------------

echo
if ((removed == 0)); then
  echo "Nothing to remove: the check-up and the updater were not installed."
else
  echo "Uninstalled."
fi
if ((!purge)); then
  kept=()
  for d in /var/log/kitchen-checkup /var/log/kitchen-update /var/lib/kitchen-checkup /var/lib/kitchen-update; do
    [[ ! -e $d ]] || kept+=("$d")
  done
  ((${#kept[@]} == 0)) || echo "Kept the reports, logs and state (--purge deletes them): ${kept[*]}"
fi
if ((!scrubs)); then
  for m in "${SCRUB_MOUNTS[@]}"; do
    t="btrfs-scrub@$(systemd-escape -p "$m").timer"
    [[ $(systemctl is-enabled "$t" 2>/dev/null) != "enabled" ]] || echo "Kept the monthly scrub $t (--disable-scrubs turns it off)."
  done
fi
echo "Kept the IgnorePkg pin in /etc/pacman.conf and the pre-refresh-pacman hook: they still guard the kitchen build."
