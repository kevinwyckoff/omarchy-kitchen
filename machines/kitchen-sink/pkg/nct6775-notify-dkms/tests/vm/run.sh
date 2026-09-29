#!/bin/bash

# Boot the real linux-omarchy kernel in QEMU with the package's modules and
# run tests/vm/init: notification on the i2c path (i2c-stub as the chip) and
# on the platform path, the register dump and its denylist (a fake chip, see
# fake-sio.c), and two test mutations of the denylist guard.
#
# Runs inside the kitchen-nct6775-test container (tests/run.sh), with the
# package at /pkg, the kernel packages at /kpkg, the headers installed, and
# /out for the log. Uses KVM when /dev/kvm is passed in, TCG otherwise.

set -uo pipefail

PKG=${PKG:-/pkg}
KPKG=${KPKG:-/kpkg}
OUT=${OUT:-/out}
VM=$PKG/tests/vm
work=$(mktemp -d)
kdirs=(/usr/lib/modules/*/build)
KDIR=${kdirs[0]}
KVER=$(basename "$(dirname "$KDIR")")

fail() {
  echo "FAIL: $*"
  exit 1
}

mkdir -p "$OUT"

# ---- The kernel and the in-tree modules the test needs, from the kernel package
kpkg=$(ls "$KPKG"/linux-omarchy-"${KVER%-omarchy}"-x86_64.pkg.tar.zst 2>/dev/null) || fail "no kernel package for $KVER in $KPKG"
m=usr/lib/modules/$KVER
tar --zstd -xf "$kpkg" -C "$work" "$m/vmlinuz" "$m/kernel/drivers/i2c/i2c-stub.ko.zst" \
  "$m/kernel/drivers/i2c/i2c-dev.ko.zst" "$m/kernel/drivers/hwmon/hwmon-vid.ko.zst" || fail "unpacking $kpkg"

root=$work/root
mkdir -p "$root"/{bin,lib/ship,lib/fake,lib/mutA,lib/mutB,proc,sys,dev,tmp}
for k in i2c/i2c-stub i2c/i2c-dev hwmon/hwmon-vid; do
  zstd -qdf "$work/$m/kernel/drivers/$k.ko.zst" -o "$root/lib/$(basename "$k").ko" || fail "zstd $k"
done

# ---- Four builds of the modules
# flavor NAME [MUTATION.patch]: the package's sources with its patches, plus
# for everything but "ship" the fake chip and the forced include
flavor() {
  local name=$1 mutation=${2:-} tree=$work/$1 p
  mkdir -p "$tree/drivers/hwmon"
  cp "$PKG"/{nct6775-core.c,nct6775-platform.c,nct6775-i2c.c,nct6775.h,lm75.h,Makefile} "$tree/drivers/hwmon/"
  for p in "$PKG"/[0-9][0-9][0-9][0-9]-*.patch $mutation; do
    patch -s -d "$tree" -Np1 --fuzz=0 --no-backup-if-mismatch -i "$p" || fail "$name: $(basename "$p") does not apply"
  done
  if [[ $name != "ship" ]]; then
    cp "$VM/fake-sio.c" "$VM/fake-sio-io.h" "$tree/drivers/hwmon/"
    {
      echo 'obj-m += fake-sio.o'
      # shellcheck disable=SC2016 # $(src) is for make, not the shell
      echo 'CFLAGS_nct6775-platform.o += -include $(src)/fake-sio-io.h'
    } >>"$tree/drivers/hwmon/Makefile"
  fi
  make -s -C "$KDIR" M="$tree/drivers/hwmon" modules >"$OUT/vm-build-$name.log" 2>&1 || {
    cat "$OUT/vm-build-$name.log"
    fail "$name: build"
  }
  if grep -E ':[0-9]+(:[0-9]+)?: (warning|error)' "$OUT/vm-build-$name.log"; then
    fail "$name: build warnings"
  fi
  cp "$tree"/drivers/hwmon/nct6775*.ko "$root/lib/$name/"
}

flavor ship
flavor fake
flavor mutA "$VM/mutations/guard-on-bad-list.patch"
flavor mutB "$VM/mutations/guard-off.patch"
cp "$work/fake/drivers/hwmon/fake-sio.ko" "$root/lib/"

# The shipped platform module must not know about the fake chip
if grep -q fake_sio_ "$root/lib/ship/nct6775.ko"; then
  fail "the ship build references fake_sio"
fi
grep -q fake_sio_outb "$root/lib/fake/nct6775.ko" || fail "the fake build does not use fake-sio"
echo "ok: built ship, fake, mutA and mutB against $KVER"

# ---- initramfs: static busybox, evwatch, the modules, /init
cp "$(command -v busybox)" "$root/bin/busybox"
ln -s busybox "$root/bin/sh" # for /init's #!; it installs the other applets
gcc -static -O2 -Wall -o "$root/bin/evwatch" "$VM/evwatch.c" || fail "evwatch"
install -m755 "$VM/init" "$root/init"
(cd "$root" && find . | cpio -o -H newc --quiet | gzip -9) >"$work/initramfs.gz"

# ---- Boot
accel=(-accel tcg -cpu max)
if [[ -w /dev/kvm ]]; then
  accel=(-accel kvm -cpu host)
fi
echo "== booting $KVER in QEMU (${accel[1]})"
timeout 900 qemu-system-x86_64 -M pc "${accel[@]}" -smp 2 -m 768 -nographic -no-reboot \
  -kernel "$work/$m/vmlinuz" -initrd "$work/initramfs.gz" \
  -append "console=ttyS0 loglevel=4 panic=-1" </dev/null |
  tr -d '\r' | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' >"$OUT/vm.log"

grep -E '^(PASS|FAIL|RESULT):' "$OUT/vm.log"
result=$(grep '^RESULT:' "$OUT/vm.log")
[[ -n $result ]] || fail "the VM run did not finish (see $OUT/vm.log)"
if ! [[ $result =~ ^RESULT:\ ([0-9]+)\ passed,\ 0\ failed$ ]] || ((BASH_REMATCH[1] == 0)); then
  fail "$result"
fi
echo "PASS: vm ($result)"
