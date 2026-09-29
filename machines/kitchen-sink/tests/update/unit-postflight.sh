#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034,SC2154,SC2329,SC2001,SC2013 # variables and stubs are read by the sourced script under test; sed runs over multi-line text

# Postflight log parsing against kitchen-sink's own pacman.log and update output.
#
# Fixtures (tests/update/fixtures), all real lines from kitchen-sink:
#   pacman-kernel-reinstall.log    2026-09-27 08:53 `pacman -S linux-omarchy`: UKI built,
#                                  signed by sbctl's mkinitcpio hook, copied; dkms "exited 6"
#   pacman-sbctl-not-signing.log   2026-09-27 08:37, before the keys existed: "not signing!"
#   pacman-full-upgrade.log        2026-09-27 11:18 keyring reinstall + omarchy update -Syu, no UKI
#   pacman-upgrade-with-uki.log    that -Syu followed by the 08:54 hook output (dkms, UKI,
#                                  loader signing): the shape of a night with a boot-chain update
#   update-output-ok.log           the 2026-09-27 `omarchy-update -y` output, escapes stripped
# Failure variants are derived below with sed, using Omarchy's exact message strings.

set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
SRC=${SRC:-$(readlink -f "$HERE/../..")}
FX=$HERE/fixtures
PF=$SRC/lib/postflight
# shellcheck source=lib.sh
source "$HERE/lib.sh"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export KITCHEN_UPDATE_CONF=/nonexistent

pf() { bash "$PF" --log-only --from 1 "$@" 2>&1; }

# ---- the real kernel reinstall passes every UKI and dkms gate
out=$(pf --pacman-log "$FX/pacman-kernel-reinstall.log" --update-rc 0); rc=$?
expect_rc "kernel reinstall: passes" 0 "$rc" "$out"
expect_match "kernel reinstall: initcpio marker" "^ok +uki: 'Initcpio image generation successful' for all 1 build" "$out"
expect_match "kernel reinstall: UKI marker" "^ok +uki: 'Unified kernel image generation successful' for all 1 build" "$out"
expect_match "kernel reinstall: sbctl signed the UKI" "^ok +uki: '✓ Signed /tmp/limine-mkinitcpio' for all 1 build" "$out"
expect_match "kernel reinstall: copied to the ESP (through the colour codes)" "^ok +uki: 'Copied: .* -> /boot/EFI/Linux/' for all 1 build" "$out"
expect_match "kernel reinstall: dkms 'exited 6' is harmless" "^ok +dkms: DKMS installs finished" "$out"
expect_match "kernel reinstall: no -Syu is a warning, not a failure" "^WARN +pacman: no full system upgrade was started" "$out"
expect_match "kernel reinstall: verdict" "^VERDICT PASS" "$out"

# ---- the real unsigned build fails
out=$(pf --pacman-log "$FX/pacman-sbctl-not-signing.log"); rc=$?
expect_rc "not signing: fails" 1 "$rc" "$out"
expect_match "not signing: sbctl's own words" "^FAIL +uki: sbctl skipped signing: Secureboot key directory doesn't exist, not signing!" "$out"
expect_match "not signing: no signed UKI" "^FAIL +uki: '✓ Signed /tmp/limine-mkinitcpio' appears 0 time" "$out"
expect_match "not signing: never copied" "^FAIL +uki: 'Copied: .* -> /boot/EFI/Linux/' appears 0 time" "$out"

# ---- the real full upgrade without a UKI
out=$(pf --pacman-log "$FX/pacman-full-upgrade.log" --update-rc 0); rc=$?
expect_rc "full upgrade: passes" 0 "$rc" "$out"
expect_match "full upgrade: transaction completed, keyring reinstall not counted" "^ok +pacman: the upgrade transaction completed \(10 packages\)" "$out"
expect_match "full upgrade: no UKI" "^info +uki: no UKI was rebuilt" "$out"

# ---- a night with a boot-chain update, against the preflight's target list
mkdir -p "$work/wd"
sed -nE 's/^\[[^]]+\] \[ALPM\] upgraded ([^ ]+) .*/\1/p' "$FX/pacman-upgrade-with-uki.log" >"$work/wd/targets.txt"
out=$(pf --pacman-log "$FX/pacman-upgrade-with-uki.log" --workdir "$work/wd" --update-rc 0 --update-log "$FX/update-output-ok.log"); rc=$?
expect_rc "boot-chain night: passes" 0 "$rc" "$out"
expect_match "boot-chain night: installed what was checked" "^ok +set: installed exactly the 10 packages" "$out"
expect_match "boot-chain night: real update output is clean" "^ok +update-log: no failure lines" "$out"
facts=$(cat "$work/wd/postflight.facts" 2>/dev/null)
expect_match "facts: one UKI build" "^uki_builds=1$" "$facts"
expect_match "facts: loader signed by the UKI run and limine-install" "^loader_signed=2$" "$facts"
expect_match "facts: ten packages changed" "^changed=10$" "$facts"

echo "extra-package" >>"$work/wd/targets.txt"
out=$(pf --pacman-log "$FX/pacman-upgrade-with-uki.log" --workdir "$work/wd" --update-rc 0)
expect_match "set drift: checked but not installed is a warning" "^WARN +set: .*checked but not installed: extra-package" "$out"
expect_match "set drift: still passes" "^VERDICT PASS" "$out"

# ---- failure variants of that night
variant() { # NAME SED-OR-AWK-PROGRAM -> file
  sed -E "$2" "$FX/pacman-upgrade-with-uki.log" >"$work/$1.log"
}
variant no-copy '/Copied:/d'
out=$(pf --pacman-log "$work/no-copy.log"); rc=$?
expect_rc "no copy to the ESP: fails" 1 "$rc" "$out"
expect_match "no copy to the ESP: named" "^FAIL +uki: 'Copied: .* -> /boot/EFI/Linux/' appears 0" "$out"

variant dkms-10 's/exited 6$/exited 10/'
out=$(pf --pacman-log "$work/dkms-10.log"); rc=$?
expect_rc "dkms build failure: fails" 1 "$rc" "$out"
expect_match "dkms build failure: named" "^FAIL +dkms: a DKMS build failed: .*exited 10" "$out"

# The thermal events' nct6775-notify is not needed to boot: its failed build is
# a WARN and the night still passes; nvidia's beside it is still a FAIL.
nct_line="[2026-09-27T08:54:40-0400] [ALPM-SCRIPTLET] ==> WARNING: \`dkms install --no-depmod nct6775-notify/7.2.5.1 -k 7.2.5-4-omarchy' exited 10"
awk -v l="$nct_line" '{ print } /dkms install --no-depmod nvidia.* exited 6$/ { print l }' "$FX/pacman-upgrade-with-uki.log" >"$work/nct-dkms.log"
out=$(pf --pacman-log "$work/nct-dkms.log"); rc=$?
expect_rc "nct6775-notify build failure: passes" 0 "$rc" "$out"
expect_match "nct6775-notify build failure: a warning, with the kernel" "^WARN +dkms: the nct6775-notify DKMS build failed for 7.2.5-4-omarchy \(exit 10\): after a reboot into it the in-tree driver loads" "$out"
expect_nomatch "nct6775-notify build failure: no FAIL line" "^FAIL" "$out"
sed -E 's/nvidia\/615.71.09 -k 7.2.5-4-omarchy. exited 6$/nvidia\/615.71.09 -k 7.2.5-4-omarchy'"'"' exited 10/' "$work/nct-dkms.log" >"$work/both-dkms.log"
out=$(pf --pacman-log "$work/both-dkms.log"); rc=$?
expect_rc "nvidia and nct6775-notify both fail: fails" 1 "$rc" "$out"
expect_match "both fail: nvidia is the FAIL" "^FAIL +dkms: a DKMS build failed: .*nvidia/615.71.09.*exited 10" "$out"
expect_match "both fail: nct6775-notify is the WARN" "^WARN +dkms: the nct6775-notify DKMS build failed" "$out"
out=$(bash -c 'source "$1"; DKMS_WARN_ONLY=""; bad=0; check_dkms "$2"; echo "bad=$bad"' _ "$PF" "$work/nct-dkms.log")
expect_match "DKMS_WARN_ONLY empty: nct6775-notify fails too" "^FAIL +dkms: a DKMS build failed: .*nct6775-notify" "$out"

# Drop the -Syu's "transaction completed" (the second one in the file).
awk '/\[ALPM\] transaction completed/ && ++n == 2 { next } { print }' "$FX/pacman-upgrade-with-uki.log" >"$work/incomplete.log"
out=$(pf --pacman-log "$work/incomplete.log"); rc=$?
expect_rc "transaction never completed: fails" 1 "$rc" "$out"
expect_match "transaction never completed: named" "^FAIL +pacman: the upgrade transaction started but never completed" "$out"

{ cat "$FX/pacman-upgrade-with-uki.log"; echo "[2026-09-29T03:40:00-0400] [ALPM] transaction interrupted"; } >"$work/interrupted.log"
out=$(pf --pacman-log "$work/interrupted.log"); rc=$?
expect_rc "interrupted transaction: fails" 1 "$rc" "$out"
expect_match "interrupted transaction: named" "^FAIL +pacman: the upgrade transaction failed or was interrupted" "$out"

# mkinitcpio's error wording, e.g. "==> ERROR: module not found: 'nvidia'"
variant mkinitcpio-error "s/(\\[ALPM-SCRIPTLET\\]) ==> Generating module dependencies/\\1 ==> ERROR: module not found: 'nvidia'/"
out=$(pf --pacman-log "$work/mkinitcpio-error.log"); rc=$?
expect_rc "mkinitcpio ERROR: fails" 1 "$rc" "$out"
expect_match "mkinitcpio ERROR: named" "^FAIL +uki: mkinitcpio reported an ERROR: ==> ERROR: module not found" "$out"

# ---- omarchy update's own failure lines (exact strings from its source)
cp "$FX/update-output-ok.log" "$work/went-wrong.log"
printf '\nSomething went wrong during the update!\n\nPlease review the output above carefully, correct the error, and retry the update.\n' >>"$work/went-wrong.log"
out=$(pf --pacman-log "$FX/pacman-full-upgrade.log" --update-rc 1 --update-log "$work/went-wrong.log"); rc=$?
expect_rc "ERR trap line: fails" 1 "$rc" "$out"
expect_match "ERR trap line: named" '^FAIL +update: omarchy update reported "Something went wrong during the update!"' "$out"
expect_match "exit status: named" "^FAIL +update: omarchy-update exited 1" "$out"

cp "$FX/update-output-ok.log" "$work/sb.log"
echo "Secure Boot needs attention. Run omarchy secureboot status before restarting." >>"$work/sb.log"
out=$(pf --pacman-log "$FX/pacman-full-upgrade.log" --update-rc 0 --update-log "$work/sb.log"); rc=$?
expect_rc "Secure Boot attention line: fails" 1 "$rc" "$out"
expect_match "Secure Boot attention line: a boot label" "^FAIL +secureboot: " "$out"

cp "$FX/update-output-ok.log" "$work/initramfs.log"
echo "Error: Initramfs generation may have failed. Review logs before restart." >>"$work/initramfs.log"
out=$(pf --pacman-log "$FX/pacman-full-upgrade.log" --update-rc 0 --update-log "$work/initramfs.log"); rc=$?
expect_rc "initramfs line: fails" 1 "$rc" "$out"
expect_match "initramfs line: a boot label" "^FAIL +uki: omarchy update reported \"Initramfs generation may have failed\"" "$out"

out=$(pf --pacman-log "$FX/pacman-full-upgrade.log" --update-rc 124); rc=$?
expect_rc "timeout: fails" 1 "$rc" "$out"
expect_match "timeout: named" "^FAIL +update: omarchy-update timed out \(exit 124\)" "$out"

# ---- no pre-update snapshot (omarchy-update carries on, and says so)
out=$(pf --pacman-log "$FX/pacman-full-upgrade.log" --update-rc 0 --update-log "$FX/update-output-ok.log")
expect_match "snapshot taken: ok" "^ok +snapshot: no snapshot failure" "$out"
cp "$FX/update-output-ok.log" "$work/nosnap.log"
# omarchy-snapshot's and omarchy-update's exact lines (escapes stripped, as root's copy has them)
printf '%s\n' 'No Snapper configs found, so no snapshot was created.' 'Continuing the update without a snapshot.' >>"$work/nosnap.log"
out=$(pf --pacman-log "$FX/pacman-full-upgrade.log" --update-rc 0 --update-log "$work/nosnap.log"); rc=$?
expect_rc "no snapshot: a warning, not a failure" 0 "$rc" "$out"
expect_match "no snapshot: named" "^WARN +snapshot: omarchy update ran WITHOUT a pre-update snapshot" "$out"

# ---- where a pacman that died stopped (its lock is all that is left)
# shellcheck source=/dev/null
source "$PF"
expect_eq "died: the real kernel reinstall's log ends in its hooks" "hooks" "$(pacman_died_during "$FX/pacman-kernel-reinstall.log")"
expect_eq "died: cut off after 'completed', before the UKI" "hooks" \
  "$(sed '/Building UKI/,$d' "$FX/pacman-kernel-reinstall.log" >"$work/cut.log"; pacman_died_during "$work/cut.log")"
expect_eq "died: in the middle of the transaction" "started" \
  "$(sed '/transaction completed/,$d' "$FX/pacman-kernel-reinstall.log" >"$work/mid.log"; pacman_died_during "$work/mid.log")"
expect_eq "died: a later pacman command started" "unknown" \
  "$({ cat "$FX/pacman-kernel-reinstall.log"; echo "[2026-09-27T09:00:00-0400] [PACMAN] Running 'pacman -Syu'"; } >"$work/later.log"; pacman_died_during "$work/later.log")"
bad=0
PACMAN_LOCK=$work/db.lck
touch "$PACMAN_LOCK"
pacman_running() { return 1; }
PACMAN_WAIT_SECS=600
start=$SECONDS
out=$(wait_for_pacman "$work/cut.log")
expect "died: no 20-minute wait for a pacman that is gone" test $((SECONDS - start)) -lt 30
expect_match "died: in its hooks: do not reboot, and what to do" "^FAIL +pacman: pacman died during its post-transaction hooks .*Do NOT reboot. At the machine: remove the lock, reinstall the kernel packages \(or run limine-mkinitcpio\)" "$out"
out=$(check_pacman_state "$work/mid.log")
expect_match "live: a lock with no pacman is a failure" "^FAIL +pacman: pacman died in the middle of its transaction" "$out"
rm -f "$PACMAN_LOCK"
out=$(check_pacman_state "$work/mid.log")
expect_match "live: a transaction that never completed" "^FAIL +pacman: the last transaction \(2026-09-27T08:53:48-0400\) never completed" "$out"
out=$(check_pacman_state "$FX/pacman-kernel-reinstall.log")
expect_match "live: no lock, last transaction ended" "^ok +pacman: no lock" "$out"
unset -f pacman_running
out=$(bash "$PF" --live-boot-only --pacman-log /nonexistent 2>&1 | head -n 1)
expect_nomatch "--live-boot-only needs no --from" "is required" "$out"

# ---- the thermal modules after the update (live; the seams answer here)
# shellcheck source=/dev/null
source "$PF"
bad=0
thermal_dkms_installed() { return 0; }
# shellcheck disable=SC2086 # one kernel per word
package_kernels() { printf '%s\n' $KERNELS; }
module_file() {
  case $1 in
    7.2.*) echo "/lib/modules/$1/updates/dkms/nct6775-core.ko.zst" ;;
    *) echo "/lib/modules/$1/kernel/drivers/hwmon/nct6775-core.ko.zst" ;;
  esac
}
KERNELS=7.2.7-1-omarchy
out=$(check_thermal_modules)
expect_match "thermal modules: built for the new 7.2 kernel" "^ok +thermal: the patched nct6775 \(nct6775-notify-dkms\) is built for 7.2.7-1-omarchy" "$out"
KERNELS="7.2.7-1-omarchy 7.3.1-1-omarchy"
out=$(check_thermal_modules; echo "bad=$bad")
expect_match "thermal modules: a 7.3 kernel gets none: events off" "^WARN +thermal: events off for 7.3.1-1-omarchy: nct6775-notify-dkms built no nct6775 module" "$out"
expect_match "thermal modules: never a FAIL" "^bad=0$" "$out"
thermal_dkms_installed() { return 1; }
expect_eq "thermal modules: nothing to say without the package" "" "$(check_thermal_modules)"
unset -f thermal_dkms_installed package_kernels module_file

# ---- helpers
# shellcheck source=/dev/null
source "$PF"
expect_eq "strip_ansi: the Copied line" "Copied: /tmp/x.efi -> /boot/EFI/Linux/y.efi" \
  "$(printf '\e[1;32mCopied:\e[0m /tmp/x.efi -> /boot/EFI/Linux/y.efi\r\n' | strip_ansi)"
expect_eq "sbctl_unsigned: the real verify output has nothing active unsigned" "" "$(sbctl_unsigned <"$FX/sbctl-verify.txt")"
expect_eq "sbctl_unsigned: an unsigned UKI is caught" "✗ /boot/EFI/Linux/omarchy_linux-omarchy.efi is not signed" \
  "$(sed 's#^✓ /boot/EFI/Linux/omarchy_linux-omarchy.efi is signed#✗ /boot/EFI/Linux/omarchy_linux-omarchy.efi is not signed#' "$FX/sbctl-verify.txt" | sbctl_unsigned)"

t_summary postflight
