#!/bin/bash

# Build the three patched modules against linux-omarchy-headers with W=1 and
# sparse, and fail on any warning in the driver's own files. Runs inside the
# kitchen-nct6775-test container (tests/run.sh), with the package at /pkg, the
# headers already installed and /out for the log and modules.

set -uo pipefail

PKG=${PKG:-/pkg}
OUT=${OUT:-/out}
kdirs=(/usr/lib/modules/*/build)
KDIR=${KDIR:-${kdirs[0]}}

fail() {
  echo "FAIL: $*"
  exit 1
}

[[ -d $KDIR ]] || fail "no kernel build tree at $KDIR"
krel=$(basename "$(dirname "$KDIR")")

tree=$(mktemp -d)
mkdir -p "$tree/drivers/hwmon" "$OUT"
(cd "$PKG" && sha256sum -c --quiet upstream.sha256) || fail "the vendored files differ from upstream.sha256"
echo "ok: vendored files match upstream.sha256"

cp "$PKG"/{nct6775-core.c,nct6775-platform.c,nct6775-i2c.c,nct6775.h,lm75.h,Makefile} "$tree/drivers/hwmon/"
for p in "$PKG"/[0-9][0-9][0-9][0-9]-*.patch; do
  patch -d "$tree" -Np1 --fuzz=0 --no-backup-if-mismatch -i "$p" >/dev/null || fail "$(basename "$p") does not apply without fuzz"
  echo "ok: $(basename "$p") applies without fuzz"
done

mod="$tree/drivers/hwmon"
log="$OUT/build-$krel.log"
if ! make -C "$KDIR" M="$mod" W=1 C=1 modules >"$log" 2>&1; then
  cat "$log"
  fail "build against $krel"
fi
grep -c '^  CHECK ' "$log" | grep -qx 3 || fail "sparse did not check all three files (see $log)"

# Any compiler or sparse diagnostic carries file:line; kbuild's own notes
# (pahole or compiler version differs) do not, and are about the container
if grep -E ':[0-9]+(:[0-9]+)?: (warning|error)' "$log"; then
  fail "warnings from W=1 or sparse (see $log)"
fi
echo "ok: built against $krel with W=1 and sparse, no warnings in the driver"

for m in nct6775-core nct6775 nct6775-i2c; do
  [[ -f $mod/$m.ko ]] || fail "$m.ko missing"
  vermagic=$(modinfo -F vermagic "$mod/$m.ko")
  [[ $vermagic == "$krel "* ]] || fail "$m.ko vermagic is '$vermagic'"
  cp "$mod/$m.ko" "$OUT/"
done
echo "ok: vermagic $krel on all three modules"

params=$(modinfo -F parm "$mod/nct6775-core.ko" | cut -d: -f1 | sort | tr '\n' ' ')
[[ $params == "notify_interval notify_pwm notify_pwm_delta notify_temp_delta " ]] || fail "nct6775-core parameters are: $params"
params=$(modinfo -F parm "$mod/nct6775.ko" | cut -d: -f1 | sort | tr '\n' ' ')
[[ $params == "dump fan_debounce force_id " ]] || fail "nct6775 parameters are: $params"
echo "ok: parameters present (nct6775-core notify_*, nct6775 dump)"

echo "PASS: build"
