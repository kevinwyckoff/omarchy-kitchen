#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034,SC2154,SC2329,SC2001,SC2013 # variables and stubs are read by the sourced script under test; sed runs over multi-line text

# safe-to-update's checks, with logind, Hyprland and PipeWire answered by stubs.
#
# Fixtures: logind-inhibitors.json (kitchen-sink's real ListInhibitors reply:
# three delay-mode sleep inhibitors) and hyprctl-clients.json (its two foot
# windows, titles dropped).

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
source "$SRC/lib/safe-to-update"
LIB_DIR=$SRC/lib
home=$work/home
rt=$work/run
mkdir -p "$home" "$rt"

# ---- remote logins: the session running the check is reported, marked, never hidden
loginctl() {
  case $1 in
    list-sessions) printf '  5 1000 desk seat0 100 user tty1 no -\n 17 1000 desk - 200 user - no -\n 18 1000 desk - 250 user - no -\n 23 1000 desk - 300 user - no -\n' ;;
    show-session)
      case $2 in
        5) printf 'Name=desk\nRemote=no\nState=active\nService=sddm-autologin\nRemoteHost=\n' ;;
        17) printf 'Name=desk\nRemote=yes\nState=active\nService=sshd\nRemoteHost=192.0.2.10\n' ;;
        18) printf 'Name=desk\nRemote=yes\nState=online\nService=sshd\nRemoteHost=192.0.2.10\n' ;;
        23) printf 'Name=desk\nRemote=yes\nState=closing\nService=sshd\nRemoteHost=192.0.2.10\n' ;;
      esac
      ;;
  esac
}
echo 17 >"$work/self"
SELF_SESSION_FILE=$work/self
out=$(check_remote_sessions)
expect_match "remote: a dry run over SSH sees its own session, marked as such" "^BUSY +remote-login: session 17 \(sshd, desk from 192.0.2.10, active\) is the session running this check" "$out"
expect_match "remote: another SSH session is a plain reason next to it" "^BUSY +remote-login: session 18 \(sshd, desk from 192.0.2.10, online\)$" "$out"
expect_nomatch "remote: the local seat session is not remote" "session 5 " "$out"
expect_nomatch "remote: a closing session is ignored" "session 23 " "$out"
echo 4294967295 >"$work/self" # what a systemd service has: no session
out=$(check_remote_sessions)
expect_nomatch "remote: under the timer no session is marked as its own" "running this check" "$out"
expect_eq "remote: under the timer both SSH sessions count" "2" "$(grep -c '^BUSY' <<<"$out")"
unset -f loginctl

# ---- logind inhibitors, with kitchen-sink's real reply
busctl() { cat "$work/inhibitors.json"; }
cp "$FX/logind-inhibitors.json" "$work/inhibitors.json"
out=$(check_inhibitors)
expect_match "inhibitors: the three always-there delay-mode ones are fine" "^ok +inhibitors: no block-mode inhibitors" "$out"
jq -c '.data[0] += [["idle","me","keep","block",1000,4242]]' "$FX/logind-inhibitors.json" >"$work/inhibitors.json"
out=$(check_inhibitors)
expect_match "inhibitors: the documented veto (systemd-inhibit --what=idle) is busy" "^BUSY +inhibitors: block-mode inhibitor held: me \(idle\): keep" "$out"
unset -f busctl

# ---- windows and audio, through a stubbed as_user
as_user() {
  case "$*" in
    *hyprctl*) cat "$work/clients.json" ;;
    *pw-dump*) cat "$work/pw.json" ;;
  esac
}
his=abc
cp "$FX/hyprctl-clients.json" "$work/clients.json"
out=$(check_windows)
expect_match "windows: kitchen-sink's two terminals are fine" "^ok +windows: no fullscreen or idle-inhibiting window" "$out"
echo '[{"class":"foot","fullscreen":0,"inhibitingIdle":false},{"class":"mpv","fullscreen":2,"inhibitingIdle":true}]' >"$work/clients.json"
out=$(check_windows)
expect_match "windows: a fullscreen video is busy" "^BUSY +windows: mpv \(fullscreen 2, idle-inhibit true\)" "$out"
echo '[{"class":"firefox","fullscreen":0,"inhibitingIdle":true}]' >"$work/clients.json"
out=$(check_windows)
expect_match "windows: a Wayland idle inhibitor is busy" "^BUSY +windows: firefox" "$out"
echo '[{"class":"old","fullscreen":true,"inhibitingIdle":false}]' >"$work/clients.json"
out=$(check_windows)
expect_match "windows: pre-0.42 boolean fullscreen still counts" "^BUSY +windows: old" "$out"
echo 'not json' >"$work/clients.json"
out=$(check_windows)
expect_match "windows: no answer from Hyprland is busy" "^BUSY +windows: cannot ask Hyprland" "$out"

cat >"$work/pw.json" <<'EOF'
[{"type":"PipeWire:Interface:Node","info":{"state":"running","props":{"media.class":"Stream/Output/Audio","application.name":"Firefox"}}},
 {"type":"PipeWire:Interface:Node","info":{"state":"suspended","props":{"media.class":"Audio/Sink","node.name":"alsa_output.hdmi"}}},
 {"type":"PipeWire:Interface:Node","info":{"state":"idle","props":{"media.class":"Stream/Input/Audio","application.name":"Discord"}}}]
EOF
out=$(check_audio)
expect_match "audio: a playing stream is busy" "^BUSY +audio: stream playing or recording: Firefox$" "$out"
echo '[{"type":"PipeWire:Interface:Node","info":{"state":"suspended","props":{"media.class":"Audio/Sink"}}}]' >"$work/pw.json"
out=$(check_audio)
expect_match "audio: a suspended HDMI sink is not" "^ok +audio: no running PipeWire streams" "$out"
unset -f as_user

# ---- gpu: owe's video wallpaper is paused while the GPU is measured
# From kitchen-sink on 2026-10-01: owe kept the decoder at 17% all night (every
# slot BUSY); paused, only Hyprland's compositing was left.
owe() { :; }
sleep() { :; }
nvidia-smi() { if [[ -e $work/owe-paused ]]; then echo "4, 0, 0"; else echo "17, 0, 17"; fi; }
as_user() {
  case "$*" in
    *"owe status"*) cat "$work/owe-status.json" ;;
    *"owe pause"*) touch "$work/owe-paused" && echo pause >>"$work/owe-calls" ;;
    *"owe resume"*) rm -f "$work/owe-paused" && echo resume >>"$work/owe-calls" ;;
  esac
}
echo '{"status":"ok","source_kind":"video","paused":false,"manual_pause":false,"reason":"visible"}' >"$work/owe-status.json"
out=$(check_gpu)
expect_match "gpu: owe's playing wallpaper is paused while measuring" "^info +gpu: owe's video wallpaper is paused while the GPU is measured" "$out"
expect_match "gpu: so it does not count" "^ok +gpu: 4% busy, no video encode/decode" "$out"
expect_eq "gpu: paused once, resumed once" "pause resume" "$(paste -sd' ' "$work/owe-calls")"
expect "gpu: the wallpaper plays again" test ! -e "$work/owe-paused"
nvidia-smi() { echo "30, 0, 25"; }
rm -f "$work/owe-calls"
out=$(check_gpu)
expect_match "gpu: a video someone watches still counts" "^BUSY +gpu: video encoder or decoder active" "$out"
expect_eq "gpu: and owe is resumed after it" "pause resume" "$(paste -sd' ' "$work/owe-calls")"
for st in '{"source_kind":"video","paused":true,"manual_pause":true,"reason":"manual"}' \
  '{"source_kind":"video","paused":true,"manual_pause":false,"reason":"occupied"}' \
  '{"source_kind":"image","paused":false,"manual_pause":false,"reason":"visible"}'; do
  echo "$st" >"$work/owe-status.json"
  rm -f "$work/owe-calls"
  out=$(check_gpu)
  expect "gpu: left alone when $(jq -r '"\(.source_kind), reason \(.reason)"' <<<"$st")" test ! -e "$work/owe-calls"
done
expect_nomatch "gpu: and no pause reported" "owe's video wallpaper" "$out"
echo '{"source_kind":"video","paused":false,"manual_pause":false,"reason":"visible"}' >"$work/owe-status.json"
rm -f "$work/owe-calls"
(
  owe_pause >/dev/null
  kill -TERM "$BASHPID"
  command sleep 2
)
expect_eq "gpu: a check killed mid-measurement still resumes owe" "pause resume" "$(paste -sd' ' "$work/owe-calls")"
unset -f owe sleep nvidia-smi as_user

# ---- agents: the newest transcript entry, not the file's mtime
mkdir -p "$home/.claude/projects/p" "$home/.pi/agent/sessions/s"
now=$(date +%s)
printf '{"type":"user","timestamp":"%s"}\n{"type":"summary","leafUuid":"x"}\n' "$(date -u -d "@$((now - 4000))" +%Y-%m-%dT%H:%M:%S.000Z)" >"$home/.claude/projects/p/a.jsonl"
printf '{"type":"message","timestamp":%s}\nnot json at all\n' "$(( (now - 600) * 1000 ))" >"$home/.pi/agent/sessions/s/b.jsonl"
expect_eq "agents: newest entry across Claude and Pi, epoch ms understood" "$((now - 600))" "$(latest_agent_entry)"
out=$(check_agents)
expect_match "agents: a Pi entry 10 min ago is busy" "^BUSY +agents: a Claude/Pi transcript was written to 10 min ago" "$out"
printf '{"type":"message","timestamp":%s}\n' "$(( (now - 5000) * 1000 ))" >"$home/.pi/agent/sessions/s/b.jsonl"
touch "$home/.claude/projects/p/a.jsonl" # a fresh mtime with an old last entry: Claude rewriting metadata
out=$(check_agents)
expect_match "agents: an old last entry is idle, whatever the mtime" "^ok +agents: no agent tool call running" "$out"

# ---- network rate, on /proc/net/dev's real layout
cat >"$work/netdev" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 1000000     100    0    0    0     0          0         0  1000000     100    0    0    0     0       0          0
enp7s0:5000       10    0    0    0     0          0         0     7000      12    0    0    0     0       0          0
EOF
expect_eq "network: rx+tx, lo excluded, name glued to the counter" "12000" "$(net_bytes "$work/netdev")"
expect_match "network: the live counter reads" "^[0-9]+$" "$(net_bytes)"

# ---- package tooling, by the kernel's 15-character process name
printf '#!/bin/bash\nsleep 20\n' >"$work/limine-snapper-sync"
chmod +x "$work/limine-snapper-sync"
"$work/limine-snapper-sync" &
sleep 0.5
out=$(check_package_tooling)
kill $! 2>/dev/null
expect_match "tooling: limine-snapper-sync is seen despite its long name" "^BUSY +tooling: package or boot tooling is running: limine-snapper-\([0-9]+\)" "$out"
out=$(check_package_tooling)
expect_match "tooling: and nothing once it is gone" "^ok +tooling: no pacman" "$out"

# ---- the pacman lock is the one hard blocker
touch /var/lib/pacman/db.lck
out=$(check_package_tooling)
rm -f /var/lib/pacman/db.lck
expect_match "pacman lock with no pacman: hard, never removed by us" "^HARD +pacman: /var/lib/pacman/db.lck exists but no package manager is running" "$out"

# ---- a failed input watch counts as busy (the container has no /dev/input)
QUIET_SECS=1
out=$(watch_input)
expect_match "input: a watch error is busy" "^BUSY +input: the input watch failed \(exit 2\)" "$out"

# ---- thresholds and verdicts
expect "at_least: 2.00 >= 2.0" at_least 2.00 2.0
if at_least 1.99 2.0; then t_fail "at_least: 1.99 < 2.0"; else t_ok "at_least: 1.99 < 2.0"; fi
out=$( (busy_n=0 hard_n=0; verdict) ); rc=$?
expect_rc "verdict: safe" 0 "$rc" "$out"
out=$( (busy_n=3 hard_n=0; verdict) ); rc=$?
expect_rc "verdict: busy is 75" 75 "$rc" "$out"
out=$( (busy_n=3 hard_n=1; verdict) ); rc=$?
expect_rc "verdict: hard outranks busy" 2 "$rc" "$out"

t_summary safe-to-update
