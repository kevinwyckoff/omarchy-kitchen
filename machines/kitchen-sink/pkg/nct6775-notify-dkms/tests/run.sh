#!/bin/bash

# Every test for nct6775-notify-dkms, from any Docker host. Nothing runs on
# the machine it starts from beyond containers (QEMU runs inside one).
#
#   tests/run.sh                  every part
#   tests/run.sh build vm         some of them
#
#   denylist   static checks of the register dump's lists and guard
#   build      the three modules against linux-omarchy-headers, W=1 and sparse
#   vm         linux-omarchy in QEMU with the modules: notification on the i2c
#              and platform paths, the dump against a fake chip, the denylist
#   package    makepkg, then pacman -U and -R with the dkms hooks
#   refresh    refresh.sh against the vendored release: no upstream change,
#              the patches apply, the build is clean (changes nothing)
#   lint       shellcheck over the package's scripts
#
# Kernel packages come from $NCT6775_KPKG_DIR (default
# ~/.cache/omarchy-kitchen/kernel), fetched from $NCT6775_KPKG_URL (default
# the Omarchy edge repo) when missing, and must match the sha256 pinned below.
# The refresh part keeps the release tarball there too.
# Logs and the built package go to $NCT6775_TEST_OUT (default a new temp dir).

set -uo pipefail
PKG=$(readlink -f "$(dirname "$0")/..")
IMAGE=kitchen-nct6775-test
PARTS=(denylist build vm package refresh lint)
(($#)) && PARTS=("$@")

# The kernel the package is built for, pinned
KERNEL=7.2.5-4
declare -A KPKG_SHA256=(
  [linux-omarchy-$KERNEL-x86_64.pkg.tar.zst]=57f7270780b9704711e585ddea7d2685ee58d6a77765f1ad446d8d022cc06c42
  [linux-omarchy-headers-$KERNEL-x86_64.pkg.tar.zst]=07733858a02bb608c789ee47bdfd24e0ef0b6fba1845f394059b9aa7768814b4
)
KPKG=${NCT6775_KPKG_DIR:-$HOME/.cache/omarchy-kitchen/kernel}
KPKG_URL=${NCT6775_KPKG_URL:-https://pkgs.omarchy.org/edge/x86_64}
OUT=${NCT6775_TEST_OUT:-$(mktemp -d /tmp/nct6775-test.XXXXXX)}
mkdir -p "$OUT"

failed=()

kernel_packages() {
  local f sum
  mkdir -p "$KPKG"
  for f in "${!KPKG_SHA256[@]}"; do
    if [[ ! -f $KPKG/$f ]]; then
      echo "fetching $f"
      curl -fsSL -o "$KPKG/$f.part" "$KPKG_URL/$f" && mv "$KPKG/$f.part" "$KPKG/$f" || return 1
    fi
    sum=$(sha256sum "$KPKG/$f" | cut -d' ' -f1)
    if [[ $sum != "${KPKG_SHA256[$f]}" ]]; then
      echo "$f: sha256 $sum, expected ${KPKG_SHA256[$f]}" >&2
      return 1
    fi
  done
}

image() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -q -t "$IMAGE" "$PKG/tests" >/dev/null
}

# in_container SCRIPT: run it with the headers installed; /dev/kvm when there is one
in_container() {
  local kvm=()
  [[ -e /dev/kvm ]] && kvm=(--device /dev/kvm)
  docker run --rm "${kvm[@]}" -v "$PKG:/pkg:ro" -v "$KPKG:/kpkg:ro" -v "$OUT:/out" "$IMAGE" bash -c "
    cp /kpkg/linux-omarchy-headers-$KERNEL-x86_64.pkg.tar.zst /tmp/ &&
      pacman -U --noconfirm /tmp/linux-omarchy-headers-$KERNEL-x86_64.pkg.tar.zst >/dev/null 2>&1 ||
      { echo 'installing the headers failed'; exit 1; }
    $1
    rc=\$?
    chown -R $(id -u):$(id -g) /out
    exit \$rc"
}

part_denylist() { python3 "$PKG/tests/test_denylist.py"; }
part_build() { in_container /pkg/tests/build.sh; }
part_vm() { in_container /pkg/tests/vm/run.sh; }
part_package() { in_container /pkg/tests/package.sh; }

part_refresh() {
  local v f
  v=$(awk '/^# version:/ { print $3 }' "$PKG/upstream.sha256")
  for f in "linux-$v.tar.xz" "linux-$v.tar.sign"; do
    [[ -f $KPKG/$f ]] || curl -fsSL -o "$KPKG/$f" "https://cdn.kernel.org/pub/linux/kernel/v${v%%.*}.x/$f" || return 1
  done
  in_container "set -o pipefail; /pkg/refresh.sh $v --tarball /kpkg/linux-$v.tar.xz | tee /out/refresh.log &&
    ! grep -q CHANGED /out/refresh.log"
}

part_lint() {
  docker run --rm -v "$PKG:/mnt:ro" -w /mnt koalaman/shellcheck:stable -x -s bash \
    refresh.sh tests/run.sh tests/build.sh tests/package.sh tests/vm/run.sh &&
    docker run --rm -v "$PKG:/mnt:ro" -w /mnt koalaman/shellcheck:stable -s sh tests/vm/init &&
    echo "shellcheck: 6 files, clean"
}

if [[ " ${PARTS[*]} " =~ \ (build|vm|package|refresh)\  ]]; then
  kernel_packages || { echo "no kernel packages for $KERNEL" >&2; exit 1; }
  image || { echo "could not build the $IMAGE image" >&2; exit 1; }
fi

for part in "${PARTS[@]}"; do
  echo "######## $part"
  if ! declare -F "part_$part" >/dev/null; then
    echo "tests/run.sh: no part '$part' (denylist, build, vm, package, refresh, lint)" >&2
    exit 2
  fi
  "part_$part" || failed+=("$part")
done

echo "########"
echo "logs and the built package: $OUT"
if ((${#failed[@]})); then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "all passed: ${PARTS[*]}"
