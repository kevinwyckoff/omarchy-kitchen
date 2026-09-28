#!/bin/bash

# Run every kitchen-update test, each suite in its own throwaway Arch container.
# Needs docker; never touches the machine it runs on beyond starting containers.
#
#   tests/update/run.sh               all suites
#   tests/update/run.sh e2e unit-*    some of them
#
# KITCHEN_TEST_IMAGE picks the base image (default archlinux:latest); each
# container installs sudo, jq and python from the Arch repos itself.

set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
ROOT=$(readlink -f "$HERE/../..")
IMAGE=${KITCHEN_TEST_IMAGE:-archlinux:latest}
SUITES=(lint unit-preflight unit-postflight unit-safe-to-update unit-news-evwatch unit-orchestrator grant-lifecycle e2e)
(( $# )) && SUITES=("$@")

failed=()
for suite in "${SUITES[@]}"; do
  suite=${suite%.sh}
  echo "======== $suite"
  if ! docker run --rm -v "$ROOT:/src:ro" -e SRC=/src "$IMAGE" bash -c "
      pacman -Sy --noconfirm --needed sudo jq python >/dev/null 2>&1 || { echo 'pacman -S failed'; exit 1; }
      bash /src/tests/update/$suite.sh"; then
    failed+=("$suite")
  fi
done

echo "======== shellcheck"
if ! docker run --rm -v "$ROOT:/mnt:ro" -w /mnt koalaman/shellcheck:stable -x -s bash \
  bin/kitchen-update lib/safe-to-update lib/preflight lib/postflight tests/update/*.sh; then
  failed+=(shellcheck)
else
  echo "---- shellcheck: clean"
fi

if (( ${#failed[@]} )); then
  echo "======== FAILED: ${failed[*]}"
  exit 1
fi
echo "======== all passed"
