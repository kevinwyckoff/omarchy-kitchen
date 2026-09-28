#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034,SC2154,SC2329,SC2001,SC2013 # variables and stubs are read by the sourced script under test; sed runs over multi-line text

# news-check.py against the real Arch news feed of 2026-09-28, and evwatch.py
# against a FIFO that stands in for /dev/input/eventN.

set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
SRC=${SRC:-$(readlink -f "$HERE/../..")}
FX=$HERE/fixtures
# shellcheck source=lib.sh
source "$HERE/lib.sh"

work=$(mktemp -d)
trap 'exec 3>&- 2>/dev/null; rm -rf -- "$work"' EXIT
NEWS=$SRC/lib/news-check.py
FEED=$FX/arch-news-2026-09-28.xml
printf '%s\n' mkinitcpio iptables which linux-omarchy >"$work/installed"

nc() { python3 "$NEWS" "$FEED" --installed "$work/installed" "$@" 2>&1; }

out=$(nc --since 2026-09-27T11:18:36-0400); rc=$?
expect_rc "news: nothing after the last upgrade (pacman.log offset form)" 0 "$rc" "$out"
expect_eq "news: and says nothing" "" "$out"

out=$(nc --since 2026-09-01T00:00:00+00:00); rc=$?
expect_rc "news: hold-all holds on the mkinitcpio item" 11 "$rc" "$out"
expect_match "news: title, date and installed package" "^HOLD 2026-09-22T09:09:27\+00:00 Mkinitcpio >=42 requires manual intervention .*\[installed: mkinitcpio\]" "$out"
expect_match "news: link on the next line" "^     https://archlinux.org/news/mkinitcpio-42" "$out"

out=$(nc --since 2026-01-01T00:00:00+00:00 --since 2026-09-01T00:00:00+00:00); rc=$?
expect_eq "news: the newest --since wins" "1" "$(grep -c '^HOLD' <<<"$out")"

out=$(nc --since 2026-06-01T00:00:00+00:00 --policy keywords); rc=$?
expect_rc "keywords: still holds on 'requires manual intervention'" 11 "$rc" "$out"
expect_match "keywords: the AUR incident only notifies" "^NEWS 2026-06-12.* Active AUR malicious packages incident" "$out"
expect_match "keywords: the election only notifies" "^NEWS 2026-06-04.* Leader Election Results" "$out"

cat >"$work/calm.xml" <<'EOF'
<?xml version="1.0"?>
<rss version="2.0"><channel><title>Arch Linux: Recent news updates</title>
<item><title>Arch Linux 2027 Leader Election Results</title><link>https://archlinux.org/news/x/</link>
<pubDate>Mon, 05 Oct 2026 12:00:00 +0000</pubDate></item>
</channel></rss>
EOF
out=$(python3 "$NEWS" "$work/calm.xml" --installed "$work/installed" --since 2026-09-28T00:00:00+00:00 --policy keywords); rc=$?
expect_rc "keywords: a calm item only notifies (10)" 10 "$rc" "$out"
out=$(python3 "$NEWS" "$work/calm.xml" --installed "$work/installed" --since 2026-09-28T00:00:00+00:00); rc=$?
expect_rc "hold-all: the same calm item holds (the decided policy)" 11 "$rc" "$out"

echo "<rss><channel><item>" >"$work/broken.xml"
out=$(python3 "$NEWS" "$work/broken.xml" --since 2026-09-28T00:00:00+00:00); rc=$?
expect_rc "news: an unreadable feed holds (3)" 3 "$rc" "$out"
out=$(nc --since yesterday); rc=$?
expect_rc "news: an unreadable --since holds (3)" 3 "$rc" "$out"

# ---- evwatch.py
EV=$SRC/lib/evwatch.py
mkfifo "$work/event0"
exec 3<>"$work/event0" # keeps a writer open, like a device that is plugged in
# struct input_event: long sec, long usec, u16 type, u16 code, s32 value
event() { python3 -c 'import struct,sys; sys.stdout.buffer.write(struct.pack("llHHi", 0, 0, int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])))' "$@"; }

out=$(python3 "$EV" 2 --glob "$work/event*"); rc=$?
expect_rc "evwatch: silence for the window" 0 "$rc" "$out"
expect_match "evwatch: says what it watched" "^no key, pointer or touch input for 2s on: $work/event0" "$out"

(sleep 0.5; event 5 2 1 >&3; event 0 0 0 >&3) &   # EV_SW (a headphone jack) then EV_SYN
out=$(python3 "$EV" 2 --glob "$work/event*"); rc=$?
expect_rc "evwatch: switch and sync events are not a person" 0 "$rc" "$out"

(sleep 1; event 1 30 1 >&3) &                      # EV_KEY: the A key
out=$(python3 "$EV" 5 --glob "$work/event*"); rc=$?
expect_rc "evwatch: a key press is someone at the desk" 1 "$rc" "$out"
expect_match "evwatch: reports the device and the time" "^key input on $work/event0 .* after 1s" "$out"

# An event split across two writes still counts.
(sleep 0.5; event 2 0 5 | head -c 10 >&3; sleep 0.3; event 2 0 5 | tail -c +11 >&3) &   # EV_REL: the mouse
out=$(python3 "$EV" 3 --glob "$work/event*"); rc=$?
expect_rc "evwatch: a pointer move split across reads" 1 "$rc" "$out"
expect_match "evwatch: named as pointer input" "^pointer input" "$out"

out=$(python3 "$EV" 1 --glob "$work/none*"); rc=$?
expect_rc "evwatch: nothing to watch is a watch error (2)" 2 "$rc" "$out"
wait

t_summary news-evwatch
