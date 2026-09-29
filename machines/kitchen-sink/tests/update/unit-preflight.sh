#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034,SC2154,SC2329,SC2001,SC2013 # variables and stubs are read by the sourced script under test; sed runs over multi-line text

# Preflight parsing and gates against kitchen-sink's own outputs.
#
# Fixtures (tests/update/fixtures), real unless noted:
#   checkupdates-2026-09-28.txt   the 15 pending updates on 2026-09-28, omarchy-dev r6663 included
#   targets-edge.txt              `pacman -Su --print` names before the pin (15)
#   targets-pinned.txt            the same with IgnorePkg = omarchy-dev omarchy-settings-dev (13)
#   targets-pinned-full.txt       "name version size repo" for those 13
#   pacman-Qu-ignored.txt         `pacman -Qu` lines IgnorePkg holds back
#   files-*.txt                   `pacman -Ql` of the installed packages, in `pacman -Fl` form;
#                                 glibc, systemd and nvidia-open-dkms are excerpts
#   sbctl-verify.txt              `sbctl verify` (machine id replaced)
#   btrfs-scrub-never.txt         `btrfs scrub status /` before any scrub (UUID replaced)
#   pacman-full-upgrade.log       for the last "starting full system upgrade"
#   arch-news-2026-09-28.xml      https://archlinux.org/feeds/news/ as fetched on 2026-09-28

set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
SRC=${SRC:-$(readlink -f "$HERE/../..")}
FX=$HERE/fixtures
# shellcheck source=lib.sh
source "$HERE/lib.sh"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export KITCHEN_UPDATE_CONF=/nonexistent

# Defines the helpers and gates without running anything (and sets PATH).
# shellcheck source=/dev/null
source "$SRC/lib/preflight"
LIB_DIR=$SRC/lib

# A fake pacman for `pacman -Fl` (the file lists) and `pacman -Qqm` (no foreign
# packages); everything else is unused here.
mkdir -p "$work/stub"
cat >"$work/stub/pacman" <<EOF
#!/bin/bash
case "\$1" in
  -Fl)
    shift
    while (( \$# )); do
      if [[ \$1 == --dbpath ]]; then shift 2; continue; fi
      cat "$FX/files-\$1.txt" 2>/dev/null
      shift
    done
    ;;
  -Qqm) exit 1 ;;
  *) exit 1 ;;
esac
EOF
# A fake curl that serves the saved news feed for `curl ... -o FILE URL`.
cat >"$work/stub/curl" <<EOF
#!/bin/bash
out=""
while (( \$# )); do [[ \$1 == -o ]] && { out=\$2; shift; }; shift; done
[[ -n \$out ]] && cp "$FX/arch-news-2026-09-28.xml" "\$out"
EOF
chmod +x "$work/stub/pacman" "$work/stub/curl"
PATH=$work/stub:$PATH

W=$work/w
DB=$W/db
mkdir -p "$DB"

# ---- parsing helpers
expect_eq "ignored_names: the pin in pacman -Qu" "omarchy-dev omarchy-settings-dev" "$(ignored_names <"$FX/pacman-Qu-ignored.txt" | paste -sd' ' -)"
expect_eq "kernel set: none of tonight's 13" "" "$(targets_matching "$KERNEL_REGEX" "$FX/targets-pinned.txt")"
# The compat strand's preflight on the machine said: boot-chain update (glibc limine limine-mkinitcpio-hook).
expect_eq "boot set: glibc and the limine pair" "glibc limine limine-mkinitcpio-hook" "$(targets_matching "$BOOT_REGEX" "$FX/targets-pinned.txt")"
expect_eq "kernel set: kernel, headers and nvidia; not firmware or api headers" "linux-omarchy linux-omarchy-headers nvidia-open-dkms dkms" \
  "$(printf '%s\n' linux-omarchy linux-omarchy-headers nvidia-open-dkms dkms linux-firmware linux-api-headers mesa | { cat >"$work/k"; targets_matching "$KERNEL_REGEX" "$work/k" "$KERNEL_EXCLUDE"; })"
expect_eq "boot set: firmware and ucode" "linux-firmware linux-firmware-amdgpu amd-ucode systemd-libs" \
  "$(printf '%s\n' linux-firmware linux-firmware-amdgpu amd-ucode systemd-libs systemd-resolvconf | { cat >"$work/b"; targets_matching "$BOOT_REGEX" "$work/b"; })"

# The compat strand counted 6 UKI trigger paths in limine-mkinitcpio-hook on the machine.
for case in limine-mkinitcpio-hook:6 limine:0 glibc:0 linux-omarchy:2 nvidia-open-dkms:1 systemd:2; do
  pkg=${case%%:*}
  expect_eq "rebuild triggers: $pkg" "${case##*:}" "$(rebuild_triggers <"$FX/files-$pkg.txt")"
done

expect_eq "sbctl: the real output has nothing active unsigned" "" "$(sbctl_unsigned <"$FX/sbctl-verify.txt")"
expect_eq "sbctl: an unsigned loader is caught" "✗ /boot/EFI/limine/limine_x64.efi is not signed" \
  "$(sed 's#^✓ /boot/EFI/limine/limine_x64.efi is signed#✗ /boot/EFI/limine/limine_x64.efi is not signed#' "$FX/sbctl-verify.txt" | sbctl_unsigned)"
expect "scrub: never scrubbed counts as clean" scrub_clean <"$FX/btrfs-scrub-never.txt"
if printf 'Error summary:    csum=12\n  Corrected:      0\n  Uncorrectable:  12\n' | scrub_clean; then
  t_fail "scrub: errors are caught"
else
  t_ok "scrub: errors are caught"
fi

expect_eq "last full upgrade: from pacman.log, with a colon in the offset" "2026-09-27T11:18:36-04:00" "$(last_full_upgrade "$FX/pacman-full-upgrade.log")"
expect_eq "newest stamp: the later one" "2026-09-28T03:40:00-04:00" "$(newest_stamp 2026-09-27T11:18:36-04:00 2026-09-28T03:40:00-04:00)"
expect_eq "newest stamp: one missing" "2026-09-27T11:18:36-04:00" "$(newest_stamp "" 2026-09-27T11:18:36-04:00)"

# ---- the pin, as it looks in the transaction
SB_MARKER=/nonexistent
cp "$FX/targets-edge.txt" "$W/targets.txt"
out=$(gate_pin_effect)
expect_match "pin broken: edge's omarchy-dev in the set holds" "^HOLD +pin: pacman would install omarchy-dev omarchy-settings-dev" "$out"
cp "$FX/targets-pinned.txt" "$W/targets.txt"
out=$(gate_pin_effect)
expect_match "pin holding: ok" "^ok +pin: none of omarchy-dev omarchy-settings-dev" "$out"

# ---- the drift guard
ignored_names <"$FX/pacman-Qu-ignored.txt" >"$W/ignored.txt"
out=$(gate_drift)
expect_match "drift: tonight's set is fine" "^ok +drift: no desktop-stack package" "$out"
printf '%s\n' hyprland quickshell >>"$W/targets.txt"
out=$(gate_drift)
expect_match "drift: hyprland while the pin holds r6663 back" "^HOLD +drift: the desktop stack would move \(hyprland quickshell\) while the pin holds omarchy-dev omarchy-settings-dev back" "$out"
: >"$W/ignored.txt"
out=$(gate_drift)
expect_match "drift: no pinned build held back, no hold" "^ok +drift: the pin is not holding" "$out"

# ---- boot-chain classification with the real file lists
cp "$FX/targets-pinned.txt" "$W/targets.txt"
out=$(gate_boot_chain)
expect_match "boot chain: CARE, not HOLD, by default" "^CARE +boot-chain: boot chain: glibc limine limine-mkinitcpio-hook; 6 files that rebuild the UKI" "$out"
expect_eq "boot chain: rebuild count saved for the ESP gate" "6" "$(cat "$W/rebuild-triggers")"
out=$(BOOT_CHAIN_POLICY=defer gate_boot_chain)
expect_match "boot chain: defer policy holds" "^HOLD +boot-chain: .*BOOT_CHAIN_POLICY=defer" "$out"
printf '%s\n' ttfx tobi-try >"$W/targets.txt"
out=$(gate_boot_chain)
expect_match "boot chain: an ordinary set is ok" "^ok +boot-chain: nothing in the set touches" "$out"

# ---- the thermal events' kernel range (an info line, never a hold)
mkdir -p "$work/src/nct6775-notify-7.2.5.1"
# The package's own dkms.conf line
echo 'BUILD_EXCLUSIVE_KERNEL="^7\.2\.[0-9]+-"' >"$work/src/nct6775-notify-7.2.5.1/dkms.conf"
DKMS_SRC_DIR=$work/src
mkdir -p "$work/doc"
printf '# version: 7.2.5\n# checked-through: 7.2.8\n' >"$work/doc/upstream.sha256"
THERMAL_DKMS_DOC=$work/doc
thermal_dkms_installed() { return 0; }
cp "$FX/files-linux-omarchy.txt" "$W/target-files.txt"
out=$(gate_thermal_kernel)
expect_match "thermal: tonight's 7.2 kernel is in range" "^ok +thermal: the pending kernel 7.2.5-4-omarchy is in nct6775-notify-dkms's range \(\^7\\\.2\\\.\[0-9\]\+-\)" "$out"
sed 's#/7.2.5-4-omarchy/#/7.2.9-1-omarchy/#' "$FX/files-linux-omarchy.txt" >"$W/target-files.txt"
out=$( (gate_thermal_kernel; echo "holds=$holds retries=$retries cares=$cares") )
expect_match "thermal: a 7.2 kernel newer than the checked release: info" "^info +thermal: the pending kernel 7.2.9-1-omarchy is in .* but newer than the last release its driver sources were checked against \(7.2.8\).*refresh.sh 7.2.9 --record. Not a reason to hold" "$out"
expect_match "thermal: ... and nothing is held" "^holds=0 retries=0 cares=0$" "$out"
sed 's#/7.2.5-4-omarchy/#/7.2.8-1-omarchy/#' "$FX/files-linux-omarchy.txt" >"$W/target-files.txt"
expect_match "thermal: the checked release itself is ok" "^ok +thermal: the pending kernel 7.2.8-1-omarchy is in" "$(gate_thermal_kernel)"
sed 's#/7.2.5-4-omarchy/#/7.3.1-1-omarchy/#' "$FX/files-linux-omarchy.txt" >"$W/target-files.txt"
out=$( (gate_thermal_kernel; echo "holds=$holds retries=$retries cares=$cares") )
expect_match "thermal: a 7.3 kernel is outside: info" "^info +thermal: the pending kernel 7.3.1-1-omarchy is outside nct6775-notify-dkms's range .*Not a reason to hold" "$out"
expect_match "thermal: and nothing is held" "^holds=0 retries=0 cares=0$" "$out"
rm -r "$work/src/nct6775-notify-7.2.5.1"
out=$(gate_thermal_kernel)
expect_match "thermal: without dkms.conf, THERMAL_KERNEL_REGEX" "^info +thermal: .*outside nct6775-notify-dkms's range \(\^7\\\.2\\\.\)" "$out"
cp "$FX/files-glibc.txt" "$W/target-files.txt"
expect_eq "thermal: no kernel in the set, nothing to say" "" "$(gate_thermal_kernel)"
thermal_dkms_installed() { return 1; }
sed 's#/7.2.5-4-omarchy/#/7.3.1-1-omarchy/#' "$FX/files-linux-omarchy.txt" >"$W/target-files.txt"
expect_eq "thermal: nothing to say without the package" "" "$(gate_thermal_kernel)"
unset -f thermal_dkms_installed

# ---- Arch news and staleness (feed served from the fixture)
mkdir -p "$work/state"
STATE_DIR=$work/state
PACMAN_LOG=$FX/pacman-full-upgrade.log
STALE_DAYS=100000
date -Iseconds >"$STATE_DIR/last-success"
out=$(gate_news)
expect_match "news: nothing since the last success" "^ok +news: no Arch news since" "$out"
expect_match "news: records when the feed was read" "." "$(cat "$W/news-checked-at")"

rm -f "$STATE_DIR/last-success"
PACMAN_LOG=/nonexistent
out=$(gate_news)
expect_match "news: no reference point at all holds" "^HOLD +news: no last-success stamp" "$out"

echo "2026-09-01T00:00:00-04:00" >"$STATE_DIR/last-success"
PACMAN_LOG=$FX/pacman-full-upgrade.log
out=$(gate_news)
expect_match "news: pacman.log's newer upgrade wins over an old stamp" "^ok +news: no Arch news since 2026-09-27T11:18:36-04:00" "$out"
PACMAN_LOG=/nonexistent
out=$(gate_news)
expect_match "news: the mkinitcpio item holds the night" "^HOLD +news: .*Mkinitcpio >=42 requires manual intervention" "$out"
expect_match "news: with its link" "archlinux.org/news/mkinitcpio-42" "$out"

STALE_DAYS=21
date -d '-30 days' -Iseconds >"$STATE_DIR/last-success"
out=$(gate_news)
expect_match "staleness: 30 days holds" "^HOLD +staleness: the last successful update was 30 days ago" "$out"
date -d '-3 days' -Iseconds >"$STATE_DIR/last-success"
out=$(gate_news)
expect_match "staleness: 3 days is fine" "^ok +staleness: last successful update 3 days ago" "$out"

# ---- verdict ranking: a hold settles the night even when something else says retry
out=$( (holds=1 retries=1 cares=1; finish) ); rc=$?
expect_rc "verdict: HOLD outranks RETRY" 20 "$rc" "$out"
out=$( (retries=1 cares=1; finish) ); rc=$?
expect_rc "verdict: RETRY outranks CARE" 40 "$rc" "$out"
out=$( (nothing=1; finish) ); rc=$?
expect_rc "verdict: nothing to do" 30 "$rc" "$out"
out=$( (cares=2; finish) ); rc=$?
expect_rc "verdict: go with care" 10 "$rc" "$out"
out=$( (finish) ); rc=$?
expect_rc "verdict: go" 0 "$rc" "$out"

t_summary preflight
