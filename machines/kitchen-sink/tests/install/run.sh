#!/bin/bash

# Run the install.sh/uninstall.sh suite in a throwaway Arch container booted
# with systemd, so daemon-reload, timers, sysusers, tmpfiles, journald and the
# real units all behave as on kitchen-sink. Needs docker.
#
#   tests/install/run.sh
#
# The container is not --privileged: it gets SYS_ADMIN and a writable cgroup
# for systemd, but /sys stays read-only and /dev its own, so the container's
# systemd starts no udev and touches none of the host's devices or consoles.

set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
ROOT=$(readlink -f "$HERE/../..")
BASE=${KITCHEN_TEST_IMAGE:-archlinux:latest}
IMAGE=kitchen-install-test
NAME=kitchen-install-test-$$

# The packages kitchen-sink has that the base image lacks. systemd-firstboot
# would wait for answers on the console, so it is masked.
if ! docker build -q -t "$IMAGE" - >/dev/null <<EOF; then
FROM $BASE
RUN pacman -Syu --noconfirm --needed sudo jq python pacman-contrib btrfs-progs diffutils binutils >/dev/null \
 && pacman -Scc --noconfirm >/dev/null \
 && systemctl mask systemd-firstboot.service
EOF
  echo "install suite: could not build the $IMAGE image" >&2
  exit 1
fi

trap 'docker rm -f "$NAME" >/dev/null 2>&1' EXIT
docker run -d --name "$NAME" --cap-add SYS_ADMIN --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  -e container=docker -v "$ROOT:/src:ro" "$IMAGE" /usr/lib/systemd/systemd >/dev/null || exit 1

state=""
for _ in {1..60}; do
  state=$(docker exec "$NAME" systemctl is-system-running 2>/dev/null)
  [[ $state == "running" || $state == "degraded" ]] && break
  sleep 1
done
if [[ $state != "running" && $state != "degraded" ]]; then
  echo "install suite: systemd in the container did not come up (state '$state')" >&2
  docker logs "$NAME" 2>&1 | tail -n 20 >&2
  exit 1
fi

docker exec -e SRC=/src "$NAME" bash /src/tests/install/test-install.sh
