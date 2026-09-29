#!/bin/bash

# makepkg the package, then install and remove it with pacman as the machine
# would, so the dkms alpm hooks build, install and remove the modules for the
# kernel. Runs inside the kitchen-nct6775-test container (tests/run.sh), with
# the package at /pkg, the kernel packages at /kpkg and /out for the package
# and the log. Nothing is loaded; modprobe only resolves.

set -uo pipefail

PKG=${PKG:-/pkg}
KPKG=${KPKG:-/kpkg}
OUT=${OUT:-/out}

passed=0
failed=0
ok() { passed=$((passed + 1)); echo "ok: $*"; }
bad() { failed=$((failed + 1)); echo "not ok: $*"; }
check() {
  local desc=$1
  shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}
fail() {
  echo "FAIL: $*"
  exit 1
}

mkdir -p "$OUT"

# ---- makepkg, as an ordinary user, from a copy of the package directory
useradd -m builder 2>/dev/null
build=/home/builder/nct6775-notify-dkms
cp -r "$PKG" "$build"
mkdir -p /home/builder/out
chown -R builder: "$build" /home/builder/out
runuser -u builder -- bash -c "cd $build && PKGDEST=/home/builder/out makepkg -f --noconfirm" >"$OUT/makepkg.log" 2>&1 || {
  cat "$OUT/makepkg.log"
  fail "makepkg"
}
pkgfile=$(ls /home/builder/out/nct6775-notify-dkms-*-any.pkg.tar.zst)
cp "$pkgfile" "$OUT/"
echo "== built $(basename "$pkgfile")"

pkgver=$(bash -c "source $PKG/PKGBUILD && echo \$pkgver")
info=$(pacman -Qip "$pkgfile")
check "package: architecture any" grep -qE '^Architecture +: any$' <<<"$info"
check "package: depends on dkms only" grep -qE '^Depends On +: dkms$' <<<"$info"
check "package: version $pkgver-1" grep -qE "^Version +: $pkgver-1\$" <<<"$info"

want="usr/lib/modprobe.d/nct6775-notify.conf
usr/share/doc/nct6775-notify-dkms/0001-hwmon-nct6775-notify-userspace-of-changes.patch
usr/share/doc/nct6775-notify-dkms/0002-hwmon-nct6775-read-only-register-dump-in-debugfs.patch
usr/share/doc/nct6775-notify-dkms/upstream.sha256
usr/src/nct6775-notify-$pkgver/Makefile
usr/src/nct6775-notify-$pkgver/dkms.conf
usr/src/nct6775-notify-$pkgver/lm75.h
usr/src/nct6775-notify-$pkgver/nct6775-core.c
usr/src/nct6775-notify-$pkgver/nct6775-i2c.c
usr/src/nct6775-notify-$pkgver/nct6775-platform.c
usr/src/nct6775-notify-$pkgver/nct6775.h"
have=$(tar --zstd -tf "$pkgfile" | grep -v '/$' | grep -v '^\.' | sort)
check "package: exactly the expected files" test "$have" = "$want"
[[ $have == "$want" ]] || diff <(echo "$want") <(echo "$have")

# The sources in the package are the vendored files with the patches applied
tree=$(mktemp -d)
mkdir -p "$tree/drivers/hwmon" "$tree/pkg"
cp "$PKG"/{nct6775-core.c,nct6775-platform.c,nct6775-i2c.c,nct6775.h,lm75.h} "$tree/drivers/hwmon/"
for p in "$PKG"/[0-9][0-9][0-9][0-9]-*.patch; do patch -s -d "$tree" -Np1 --fuzz=0 -i "$p"; done
tar --zstd -xf "$pkgfile" -C "$tree/pkg"
check "package: /usr/src holds the patched sources" diff -r -x Makefile -x dkms.conf "$tree/drivers/hwmon" "$tree/pkg/usr/src/nct6775-notify-$pkgver"
check "package: dkms.conf has the version filled in" grep -qx "PACKAGE_VERSION=\"$pkgver\"" "$tree/pkg/usr/src/nct6775-notify-$pkgver/dkms.conf"
# kitchen-sink's preflight and check-up read the release it was checked through here
check "package: the installed upstream.sha256 records checked-through" \
  grep -qE '^# checked-through: [0-9]+\.[0-9]+(\.[0-9]+)?$' "$tree/pkg/usr/share/doc/nct6775-notify-dkms/upstream.sha256"

# ---- Install the kernel, its headers and dkms, then the package (runs the hooks)
kpkgs=()
for f in "$KPKG"/linux-omarchy-[0-9]*-x86_64.pkg.tar.zst "$KPKG"/linux-omarchy-headers-*-x86_64.pkg.tar.zst; do
  cp "$f" /tmp/ # without its .sig next to it: tests/run.sh checked the sha256
  kpkgs+=("/tmp/$(basename "$f")")
done
# The kernel wants an initramfs generator; this container has no boot to make one for
pacman -U --noconfirm --needed --assume-installed initramfs "${kpkgs[@]}" >"$OUT/pacman-kernel.log" 2>&1 || {
  cat "$OUT/pacman-kernel.log"
  fail "installing the kernel packages"
}
kver=$(basename /usr/lib/modules/*-omarchy)
intree=/usr/lib/modules/$kver/kernel/drivers/hwmon
updates=/usr/lib/modules/$kver/updates/dkms
# Where modprobe would load a module from; modinfo says /lib/modules, a symlink
resolves() { readlink -f "$(modinfo -k "$kver" -F filename "$1")"; }
check "before: nct6775_core resolves to the in-tree module" test "$(resolves nct6775_core)" = "$intree/nct6775-core.ko.zst"

pacman -U --noconfirm "$pkgfile" >"$OUT/pacman-install.log" 2>&1
rc=$?
cat "$OUT/pacman-install.log"
check "pacman -U succeeds (the dkms install hook ran)" test $rc -eq 0
check "the hook built for $kver" grep -q "dkms install --no-depmod nct6775-notify/$pkgver -k $kver" "$OUT/pacman-install.log"
check "dkms status: installed" grep -q "nct6775-notify/$pkgver, $kver, x86_64: installed" <<<"$(dkms status 2>&1)"
makelog=$(find /var/lib/dkms/nct6775-notify -name make.log | head -1)
[[ -n $makelog ]] && cp "$makelog" "$OUT/dkms-make.log"
check "the DKMS build log has no compiler warnings" test -n "$makelog" -a -z "$(grep -E ':[0-9]+(:[0-9]+)?: (warning|error)' "$makelog" 2>/dev/null)"
for m in nct6775_core:nct6775-core nct6775:nct6775 nct6775_i2c:nct6775-i2c; do
  check "after: ${m%%:*} resolves to $updates/${m#*:}.ko.zst" test "$(resolves "${m%%:*}")" = "$updates/${m#*:}.ko.zst"
done
deps=$(modprobe -S "$kver" --show-depends nct6775)
echo "$deps"
check "modprobe nct6775 would load both updates/dkms modules" test "$(grep -c "^insmod /lib/modules/$kver/updates/dkms/nct6775" <<<"$deps")" -eq 2
check "the modprobe.d defaults apply" grep -qx 'options nct6775_core notify_interval=1000 notify_pwm_delta=3 notify_temp_delta=1000' <<<"$(modprobe -c | grep '^options nct6775')"
check "the dump is not switched on by the defaults" test "$(modprobe -c | grep -c 'nct6775 dump')" -eq 0
check "the built nct6775 has the dump parameter" grep -qx dump <<<"$(modinfo -k "$kver" -F parm nct6775 | cut -d: -f1)"
check "the built nct6775_core has the notify parameters" test "$(modinfo -k "$kver" -F parm nct6775_core | grep -c '^notify_')" -eq 4

# Kernels outside BUILD_EXCLUSIVE_KERNEL are skipped (the in-tree driver stays)
regex=$(sed -n 's/^BUILD_EXCLUSIVE_KERNEL="\(.*\)"$/\1/p' "$tree/pkg/usr/src/nct6775-notify-$pkgver/dkms.conf")
check "BUILD_EXCLUSIVE_KERNEL covers $kver and 7.2.9-1-omarchy" bash -c "[[ $kver =~ $regex && 7.2.9-1-omarchy =~ $regex ]]"
check "BUILD_EXCLUSIVE_KERNEL excludes 7.3.0-1-omarchy and 7.20.1-1" bash -c "! [[ 7.3.0-1-omarchy =~ $regex || 7.20.1-1 =~ $regex ]]"

# ---- Remove it: the dkms remove hook takes the modules away, the in-tree driver is back
pacman -R --noconfirm nct6775-notify-dkms >"$OUT/pacman-remove.log" 2>&1
rc=$?
cat "$OUT/pacman-remove.log"
check "pacman -R succeeds (the dkms remove hook ran)" test $rc -eq 0
check "the hook removed it for $kver" grep -q "dkms remove --no-depmod nct6775-notify/$pkgver -k $kver" "$OUT/pacman-remove.log"
check "after remove: nct6775_core resolves to the in-tree module again" test "$(resolves nct6775_core)" = "$intree/nct6775-core.ko.zst"
check "after remove: nothing left in updates/dkms, /usr/src or /var/lib/dkms" \
  test -z "$(ls -d "$updates"/nct6775* /usr/src/nct6775-notify-* /var/lib/dkms/nct6775-notify 2>/dev/null)"
check "after remove: the modprobe.d defaults are gone" test ! -e /usr/lib/modprobe.d/nct6775-notify.conf

echo "== $passed passed, $failed failed"
((failed == 0)) || fail "package"
echo "PASS: package ($(basename "$pkgfile"))"
