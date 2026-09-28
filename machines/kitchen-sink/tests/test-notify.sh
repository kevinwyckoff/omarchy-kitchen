#!/bin/bash

# Tests for lib/notify: argument handling, the session-bus wait, and what it
# hands to Omarchy's notification commands, which are stubbed here. It uses
# notify's two test-only variables to point at a fake /run/user and a PATH
# holding the stubs.

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$here/lib.sh"
notify=$here/../lib/notify

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
me=$(id -un)
uid=$(id -u)
chmod 0755 "$T"
mkdir -p "$T/stubs" "$T/run/$uid"

# The stubs run under notify's env -i, so they take their orders from files.
cat >"$T/stubs/omarchy-notification-wait" <<EOF
#!/bin/bash
echo "\$1" >"$T/wait-arg"
[[ \$OMARCHY_PATH == "/usr/share/omarchy" ]] || exit 1
exit \$(cat "$T/wait-rc")
EOF
cat >"$T/stubs/omarchy-notification-send" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >"$T/send-args"
env >"$T/send-env"
rc=\$(cat "$T/send-rc")
((rc == 0)) && echo 7 || echo "Unknown option: --bogus" >&2
exit \$rc
EOF
chmod +x "$T/stubs/"*

bus_up() { python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/run/$uid/bus"; }
bus_down() { rm -f "$T/run/$uid/bus"; }

run_notify() {
  rm -f "$T/send-args" "$T/wait-arg"
  NOTIFY_RUNTIME_ROOT=$T/run NOTIFY_USER_PATH=$T/stubs:/usr/bin "$notify" --user "$me" "$@" 2>"$T/stderr"
  rc=$?
  err=$(cat "$T/stderr")
  args=$(cat "$T/send-args" 2>/dev/null)
}

echo 0 >"$T/wait-rc"
echo 0 >"$T/send-rc"

# ---- a toast is sent ----------------------------------------------------------

bus_up
run_notify --urgency critical --title "kitchen-sink check-up: 1 problem" --body $'secureboot: needs attention\nunits: 1 failed' \
  --open "$T/log dir/2026-09-28.txt" --app-name kitchen-sink-checkup --glyph $'\xef\x88\x9e'
expect_eq "sent exit" "$rc" 0
expect_has "sent log" "$err" "notify: toast 7 sent to $me (critical, kitchen-sink-checkup): kitchen-sink check-up: 1 problem"
expect_has "send options" "$args" $'--app-name\nkitchen-sink-checkup\n-u\ncritical\n-p\n-g\n\xef\x88\x9e'
expect_has "send headline and body" "$args" $'kitchen-sink check-up: 1 problem\nsecureboot: needs attention\nunits: 1 failed\n--exec'
expect_has "send click action" "$args" $'--exec\nomarchy-launch-floating-terminal-with-presentation\nless\n-R\n'
expect_has "send env bus" "$(cat "$T/send-env")" "DBUS_SESSION_BUS_ADDRESS=unix:path=$T/run/$uid/bus"
expect_has "send env omarchy" "$(cat "$T/send-env")" "OMARCHY_PATH=/usr/share/omarchy"
expect_eq "server wait floor" "$(cat "$T/wait-arg")" 10

# The launcher joins its arguments and runs them with bash -c; the quoted path
# must come out of that as the original path, spaces and all.
quoted=$(sed -n '/^-R$/{n;p;}' "$T/send-args")
expect_eq "open path survives bash -c" "$(bash -c "printf '%s' $quoted")" "$T/log dir/2026-09-28.txt"

# --flag=value, and a body that starts with a dash
run_notify --urgency=low --title=Hello --body="-50% disk" --open=
expect_has "equals form" "$args" $'-u\nlow\n-p\nHello\n-50% disk'
expect_eq "no click without --open" "$(grep -c -- --exec <<<"$args")" 0

# ---- defaults and bad input ---------------------------------------------------

run_notify --urgency urgent --body "text"
expect_has "bad urgency warned" "$err" "unknown urgency 'urgent'"
expect_has "bad urgency uses normal" "$args" $'-u\nnormal'
expect_has "default title and app" "$args" $'--app-name\nkitchen-sink\n-u\nnormal\n-p\nkitchen-sink\ntext'

run_notify --title "T" stray --body
expect_eq "stray args exit" "$rc" 0
expect_has "stray arg logged" "$err" "unknown argument 'stray'"
expect_has "missing value logged" "$err" "--body needs a value"
expect_has "stray args still send" "$args" "T"

"$notify" --user no-such-user-kitchen --title T 2>"$T/stderr"
expect_eq "unknown user exit" "$?" 0
expect_has "unknown user log" "$(cat "$T/stderr")" "no user 'no-such-user-kitchen'"

"$notify" --help >"$T/help"
expect_has "help" "$(cat "$T/help")" "Usage: notify --urgency"

# ---- no session ---------------------------------------------------------------

bus_down
start=$SECONDS
run_notify --title "no bus"
expect_eq "no bus exit" "$rc" 0
expect_has "no bus log" "$err" "has no session bus (not logged in); toast skipped: no bus"
expect_eq "no bus, no send" "$args" ""
expect_eq "no bus, no wait by default" "$(((SECONDS - start) < 2))" 1

# The bus appears while notify waits for it
(sleep 1 && bus_up) &
run_notify --title "late bus" --wait 6
wait
expect_has "late bus sent" "$err" "toast 7 sent"

# ---- the shell does not answer, or the send fails -----------------------------

echo 1 >"$T/wait-rc"
run_notify --title "no server"
expect_eq "no server exit" "$rc" 0
expect_has "no server log" "$err" "did not answer within 10s"
expect_eq "no server, no send" "$args" ""
echo 0 >"$T/wait-rc"

echo 1 >"$T/send-rc"
run_notify --title "send fails"
expect_eq "send fails exit" "$rc" 0
expect_has "send fails log" "$err" "omarchy-notification-send failed (exit 1: Unknown option: --bogus"
echo 0 >"$T/send-rc"

# ---- journal priority ---------------------------------------------------------

# Under systemd, JOURNAL_STREAM names stderr's device:inode; fake that with a file.
touch "$T/journal"
(
  exec 2>"$T/journal"
  JOURNAL_STREAM=$(stat -c '%d:%i' "$T/journal") NOTIFY_RUNTIME_ROOT=$T/run NOTIFY_USER_PATH=$T/stubs:/usr/bin \
    "$notify" --user "$me" --title "journal"
)
expect_has "journal priority prefix" "$(cat "$T/journal")" "<6>notify: toast 7 sent"

finish test-notify
