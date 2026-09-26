#!/bin/bash
# step.sh <name> <wait-seconds> [keys...]: send keys to the VM over QMP, wait,
# then save a screenshot as ./<name>.png in the current directory.
# QMP defaults to 127.0.0.1:4444; set QMP=host:port to change it.

here=$(dirname "$(readlink -f "$0")")
qmp=${QMP:-127.0.0.1:4444}
name=$1
wait=$2
shift 2

if (( $# > 0 )); then
  python3 "$here/keys.py" "$qmp" "$@"
fi
sleep "$wait"
python3 "$here/shot.py" "$qmp" "$PWD/$name.png" >/dev/null && echo "$PWD/$name.png"
