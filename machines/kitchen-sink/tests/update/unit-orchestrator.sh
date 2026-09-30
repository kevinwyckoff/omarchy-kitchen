#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034,SC2154,SC2329,SC2001,SC2013 # variables and stubs are read by the sourced script under test; sed runs over multi-line text

# kitchen-update's own helpers: the Omarchy tripwire, the user environment it
# passes on, the command line, the night bookkeeping and the reboot levels.
#
# Fixtures:
#   omarchy-r6647/       omarchy-update, -orphan-pkgs, -restart, -aur-pkgs and
#                        omarchy-snapshot from the kitchen build kitchen-sink runs
#                        (sha256 identical to its /usr/bin copies)
#   omarchy-r6663/       upstream edge's omarchy-update (the build the pin holds back)
#   user-manager-env.json  kitchen-sink's user manager Environment as busctl returns it

set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
SRC=${SRC:-$(readlink -f "$HERE/../..")}
FX=$HERE/fixtures
# shellcheck source=lib.sh
source "$HERE/lib.sh"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export KITCHEN_UPDATE_CONF=/nonexistent

# shellcheck source=/dev/null
source "$SRC/bin/kitchen-update"
STATE_DIR=$work/state
mkdir -p "$STATE_DIR"

# ---- the tripwire, against the real Omarchy code
OMARCHY_BIN=$FX/omarchy-r6647
out=$(gate_tripwire)
expect_match "tripwire: the installed kitchen build (r6647) passes" "^ok +tripwire: omarchy-update, -orphan-pkgs, -restart and -aur-pkgs behave as designed" "$out"
mkdir -p "$work/r6663"
cp "$FX/omarchy-r6647/omarchy-update-orphan-pkgs" "$FX/omarchy-r6647/omarchy-update-restart" "$FX/omarchy-r6647/omarchy-update-aur-pkgs" "$work/r6663/"
cp "$FX/omarchy-r6663/omarchy-update" "$work/r6663/"
OMARCHY_BIN=$work/r6663
out=$(gate_tripwire)
expect_match "tripwire: upstream r6663's omarchy-update keeps the same internals" "^ok +tripwire" "$out"
mkdir -p "$work/changed"
cp "$FX"/omarchy-r6647/* "$work/changed/"
sed -i 's/OMARCHY_UPDATE_LOGGED:-/OMARCHY_UPDATE_TRANSCRIPT:-/' "$work/changed/omarchy-update"
sed -i 's/! -t 0 || ! -t 1/! -t 1/' "$work/changed/omarchy-update-orphan-pkgs"
OMARCHY_BIN=$work/changed
holds=()
out=$(gate_tripwire)
expect_match "tripwire: a renamed variable and a new prompt rule hold the night" "^HOLD +tripwire: .* changed in: omarchy-update omarchy-update-orphan-pkgs; re-check" "$out"
rm -f "$work/changed/omarchy-update"
holds=()
out=$(gate_tripwire)
expect_match "tripwire: a missing omarchy-update is named once, not once per needle" "^HOLD +tripwire: .* changed in: omarchy-update omarchy-update-orphan-pkgs; re-check" "$out"
# The AUR guard waits for this exact header; a new wording must hold the night.
cp "$FX"/omarchy-r6647/* "$work/changed/"
sed -i 's/Update AUR packages/Updating AUR packages/' "$work/changed/omarchy-update-aur-pkgs"
holds=()
out=$(gate_tripwire)
expect_match "tripwire: a reworded AUR header holds the night (the AUR guard would miss it)" "^HOLD +tripwire: .* changed in: omarchy-update-aur-pkgs; re-check" "$out"
cp "$FX"/omarchy-r6647/* "$work/changed/"
sed -i 's/Continuing the update without a snapshot/Carrying on without a snapshot/' "$work/changed/omarchy-update"
holds=()
out=$(gate_tripwire)
expect_match "tripwire: a reworded no-snapshot line holds the night (the postflight would miss it)" "^HOLD +tripwire: .* changed in: omarchy-update; re-check" "$out"
expect_eq "the AUR guard's header is the fixture's, escapes stripped" "$AUR_HEADER" \
  "$(bash -c "$(grep -F 'Update AUR packages' "$FX/omarchy-r6647/omarchy-update-aur-pkgs")" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^$')"

# ---- the user's environment, from kitchen-sink's real manager Environment
DESKTOP_USER=kevinwyckoff uid=1000 gid=1000 home=/home/kevinwyckoff shell=/usr/bin/bash kgid=969
OMARCHY_BIN=/usr/bin OMARCHY_ROOT=/usr/share/omarchy
as_user() { cat "$FX/user-manager-env.json"; }
user_groups() { echo "1000,998"; }
expect "read_user_env: parses busctl's JSON" read_user_env
expect_eq "read_user_env: 179 variables" "179" "${#uenv[@]}"
expect_eq "read_user_env: a value with spaces survives" "omarchy-launch-editor --inline" "${uenv[EDITOR]}"
build_run
envs=$(printf '%s\n' "${run_env[@]}")
expect_eq "build_run: exactly the whitelist, in order, plus OMARCHY_UPDATE_LOGGED" \
  "HOME USER LOGNAME SHELL LANG PATH WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS OMARCHY_PATH OMARCHY_UPDATE_LOGGED" \
  "$(sed 's/=.*//' <<<"$envs" | paste -sd' ' -)"
expect_match "build_run: the session's PATH, mise shims and all" "^PATH=/usr/share/omarchy/bin:/home/kevinwyckoff/.local/share/mise/shims:" "$envs"
expect_match "build_run: the live Hyprland instance" "^HYPRLAND_INSTANCE_SIGNATURE=efb50993780079460b0cbed1363e2166a2de1d9f_1790521761_808487454$" "$envs"
expect_eq "build_run: the command" \
  "timeout --foreground -k 5m 100m setpriv --reuid=1000 --regid=1000 --groups=1000,998,969 -- env -i" \
  "${run_cmd[*]:0:12}"
expect_eq "build_run: the user-side script" \
  "exec > >(exec tee /tmp/omarchy-update.log) 2>&1; exec /usr/bin/omarchy-update -y </dev/null" \
  "${run_cmd[-1]}"
expect_eq "build_run: run by /bin/bash -c" "/bin/bash -c" "${run_cmd[-3]} ${run_cmd[-2]}"

uenv[LANG]=$'en_US.UTF-8\nBASH_ENV=/tmp/x'
uenv[OMARCHY_PATH]=/home/kevinwyckoff/omarchy-dev
out=$(build_run; printf '%s\n' "${run_env[@]}")
expect_nomatch "build_run: a value with a newline is dropped, not split" "^(LANG|BASH_ENV)=" "$out"
expect_match "build_run: OMARCHY_PATH stays the packaged root" "^OMARCHY_PATH=/usr/share/omarchy$" "$out"
unset -f as_user user_groups

expect_eq "shell_words: plain words bare, the script quoted" \
  "timeout --groups=1,2 /bin/bash -c 'exec > >(tee x) 2>&1'" \
  "$(shell_words timeout --groups=1,2 /bin/bash -c 'exec > >(tee x) 2>&1')"

# ---- reasons: a dry run's two passes of instant checks
# From kitchen-sink's dry run on 2026-09-30: a second SSH session holding an idle
# inhibitor, a key pressed in the quiet window, and minutes ticking between passes.
W=$work/reasons
mkdir -p "$W"
cat >"$W/activity.out" <<'EOF'
info  pass 1: instant checks
BUSY  inhibitors: block-mode inhibitor held: kitchen-negative-test (idle): negative dry run
BUSY  remote-login: session 359 (sshd, desk from 192.0.2.10, active)
BUSY  remote-login: session 360 (sshd, desk from 192.0.2.10, active) is the session running this check: a dry run over SSH always sees itself; the timer's run has no session
BUSY  terminals: typed into /dev/pts/0 15 min ago (limit 30 min)
BUSY  agents: a Claude/Pi transcript was written to 16 min ago (limit 30 min)
BUSY  audio: stream playing or recording: firefox
info  input: watching keyboard, mouse and touch for 60s
BUSY  input: key input on /dev/input/event2 (Logitech K400 Plus) after 29s
info  pass 2: instant checks again (anything that started during the quiet window)
BUSY  inhibitors: block-mode inhibitor held: kitchen-negative-test (idle): negative dry run
BUSY  remote-login: session 359 (sshd, desk from 192.0.2.10, active)
BUSY  remote-login: session 360 (sshd, desk from 192.0.2.10, active) is the session running this check: a dry run over SSH always sees itself; the timer's run has no session
BUSY  terminals: typed into /dev/pts/0 16 min ago (limit 30 min)
BUSY  agents: a Claude/Pi transcript was written to 17 min ago (limit 30 min)
VERDICT BUSY
EOF
out=$(reasons_from activity BUSY)
expect_eq "reasons: each busy check once, with the second pass's numbers" "7" "$(grep -c . <<<"$out")"
expect_match "reasons: the terminal as the second pass saw it" "^terminals: typed into /dev/pts/0 16 min ago" "$out"
expect_nomatch "reasons: not the first pass's stale minutes" "15 min ago|agents: .* 16 min ago" "$out"
expect_eq "reasons: both SSH sessions kept" "2" "$(grep -c '^remote-login:' <<<"$out")"
expect_match "reasons: a check only the first pass saw is kept" "^audio: stream playing" "$out"
expect_match "reasons: the input watch is kept" "^input: key input on /dev/input/event2" "$out"
printf 'HOLD  news: an Arch news item\nHOLD  news: an Arch news item\nHOLD  esp: 12 MiB free\n' >"$W/preflight.out"
expect_eq "reasons: other helpers only lose exact repeats" "news: an Arch news item|esp: 12 MiB free" "$(reasons_from preflight HOLD | paste -sd'|')"

# ---- night bookkeeping
NIGHT=2026-09-28
W=$work/w
mkdir -p "$W"
printf 'glibc a -> b\nlimine c -> d\n' >"$W/pending.txt"
pending_count=2
busys=("activity: someone is typing" 'odd "quotes" and a \ backslash')
write_status BUSY >/dev/null
expect "status: valid JSON with odd characters in a reason" jq -e -r .state "$STATE_DIR/status.json" >/dev/null
expect_eq "status: BUSY is not settled" "false" "$(jq -r .settled "$STATE_DIR/status.json")"
expect_eq "status: the reasons" 'odd "quotes" and a \ backslash' "$(jq -r '.reasons[1]' "$STATE_DIR/status.json")"
expect_eq "status: the pending list" "2" "$(jq -r '.pending | length' "$STATE_DIR/status.json")"
expect_eq "status: first night without an update" "1" "$(jq -r .nights_without_update "$STATE_DIR/status.json")"
write_status BUSY >/dev/null
write_status DEFERRED >/dev/null
expect_eq "status: one night counts once" "1" "$(jq -r .nights_without_update "$STATE_DIR/status.json")"
if settled_state >/dev/null; then t_fail "settled: DEFERRED lets a manual run try again"; else t_ok "settled: DEFERRED lets a manual run try again"; fi
NIGHT=2026-09-29
holds=("news: Arch news since ...")
write_status HELD >/dev/null
expect_eq "status: the next night adds one" "2" "$(jq -r .nights_without_update "$STATE_DIR/status.json")"
expect_match "settled: HELD settles the night" "^HELD at " "$(settled_state)"
NIGHT=2026-09-30
if settled_state >/dev/null; then t_fail "settled: not for the next night"; else t_ok "settled: not for the next night"; fi
pending_count=-1
busys=("pending: checkupdates failed")
write_status BUSY >/dev/null
expect_eq "status: a night with no pending list is not counted" "2" "$(jq -r .nights_without_update "$STATE_DIR/status.json")"
NIGHT=2026-10-01
state_written=0
pacman_from=1234
write_status RUNNING >/dev/null
expect_eq "status: RUNNING is not settled" "false" "$(jq -r .settled "$STATE_DIR/status.json")"
expect_eq "status: RUNNING keeps where the update's pacman.log starts" "1234" "$(jq -r .pacman_from "$STATE_DIR/status.json")"
expect_eq "status: RUNNING is not the night's result (the run still owes one)" "0" "$state_written"
if settled_state >/dev/null; then t_fail "settled: RUNNING does not settle the night"; else t_ok "settled: RUNNING does not settle the night"; fi
pacman_from=""
notes=("13 packages updated")
warnings=("snapshot: omarchy update ran WITHOUT a pre-update snapshot")
write_status DONE >/dev/null
expect_eq "status: DONE resets the count" "0" "$(jq -r .nights_without_update "$STATE_DIR/status.json")"
expect_eq "status: a history line per write" "7" "$(wc -l <"$STATE_DIR/history.jsonl")"
expect_eq "status: the warnings" "snapshot: omarchy update ran WITHOUT a pre-update snapshot" "$(jq -r '.warnings[0]' "$STATE_DIR/status.json")"
expect_eq "status: a final state is the night's result" "1" "$state_written"
amend_status "group: killed 1 process" >/dev/null
expect_eq "amend: a warning added to tonight's status" "2" "$(jq -r '.warnings | length' "$STATE_DIR/status.json")"
expect_eq "amend: the state stays" "DONE" "$(jq -r .state "$STATE_DIR/status.json")"
NIGHT=2026-10-02
amend_status "not for another night" >/dev/null
expect_eq "amend: another night's status is left alone" "2" "$(jq -r '.warnings | length' "$STATE_DIR/status.json")"
warnings=()

# ---- what to do about a failed boot check
expect_eq "remedy: a missing nvidia module names the kernel" \
  "rebuild the nvidia module with sudo dkms autoinstall -k 7.2.6-1-omarchy, then the UKI with sudo limine-mkinitcpio" \
  "$(echo 'nvidia: no nvidia-open-dkms module for 7.2.6-1-omarchy: a black screen on the GTX 1650 after reboot' | boot_remedy)"
expect_eq "remedy: a stale UKI" "rebuild and sign the UKI with sudo limine-mkinitcpio" \
  "$(echo "kernel: /boot/EFI/Linux/omarchy_linux-omarchy.efi carries '7.2.5-4-omarchy', not the installed kernel 7.2.6-1-omarchy" | boot_remedy)"
expect_match "remedy: pacman first, Secure Boot last" "^finish pacman's work first.*; run omarchy secureboot status and do what it says$" \
  "$(printf '%s\n' 'secureboot: omarchy secureboot status is NOT clean' 'pacman: the upgrade transaction failed' | boot_remedy)"
expect_nomatch "remedy: no 'until secureboot status is clean' for a DKMS failure" "secureboot" \
  "$(echo 'dkms: a DKMS build failed: exited 10' | boot_remedy)"

# ---- which slot is the night's last
NIGHT=$(date +%F)
systemctl() { echo "@$next_epoch"; }
next_epoch=$(date -d "$NIGHT 23:59:00" +%s)
if last_slot; then t_fail "last slot: the timer fires again tonight"; else t_ok "last slot: the timer fires again tonight"; fi
next_epoch=$(date -d "$NIGHT +1 day 02:30" +%s)
expect "last slot: the timer's next firing is tomorrow" last_slot
systemctl() { echo ""; }
LAST_SLOT=00:00
expect "last slot, no timer: after LAST_SLOT" last_slot
LAST_SLOT=23:59
if (( 10#$(date +%H%M) < 2359 )); then
  if last_slot; then t_fail "last slot, no timer: before LAST_SLOT"; else t_ok "last slot, no timer: before LAST_SLOT"; fi
fi
unset -f systemctl

# ---- reboot levels
reboot_level=none reboot_reasons=()
reboot_add recommended "the UKI was rebuilt"
expect_eq "reboot: recommended" "recommended" "$reboot_level"
reboot_add needed "kernel updated"
expect_eq "reboot: needed wins" "needed" "$reboot_level"
reboot_add recommended "the loader was re-signed"
expect_eq "reboot: and stays needed" "needed" "$reboot_level"
expect_eq "reboot: every reason kept" "3" "${#reboot_reasons[@]}"

# ---- a reboot owed from an earlier night keeps its date and is not repeated
W=$work/w2
mkdir -p "$W" "$work/home"
home=$work/home uid=99999
echo "uki_builds=1" >"$W/postflight.facts"
jq -n --arg b "$(cat /proc/sys/kernel/random/boot_id)" \
  '{since: "2026-09-27T03:41:00-04:00", level: "recommended", reasons: ["the UKI was rebuilt"], boot_id: $b}' >"$STATE_DIR/reboot-pending"
reboot_level=none reboot_reasons=() reboot_since=""
carry_reboot_pending
reboot_check >/dev/null
expect_eq "reboot owed: still recommended" "recommended" "$reboot_level"
expect_eq "reboot owed: the reason once, not twice" "1" "${#reboot_reasons[@]}"
expect_eq "reboot owed: pending since the first night" "2026-09-27T03:41:00-04:00" "$(jq -r .since "$STATE_DIR/reboot-pending")"
jq '.boot_id = "another-boot"' "$STATE_DIR/reboot-pending" >"$work/rp" && mv "$work/rp" "$STATE_DIR/reboot-pending"
reboot_level=none reboot_reasons=() reboot_since=""
carry_reboot_pending
expect_eq "reboot owed: forgotten after a reboot" "none" "$reboot_level"
expect "reboot owed: its file removed" test ! -e "$STATE_DIR/reboot-pending"

t_summary orchestrator
