#!/bin/bash

# Move the vendored nct6775 sources to another kernel release, or check that
# the patches still fit one. Meant for an Arch container with base-devel,
# sparse and the target kernel's headers (linux-omarchy-headers) installed;
# tests/run.sh shows one way to set that up.
#
#   refresh.sh 7.2.7              diff, patch and build; change nothing here
#   refresh.sh 7.2.7 --update     ...and then move this package to 7.2.7:
#                                 sources, upstream.sha256, PKGBUILD, dkms.conf
#   refresh.sh 7.2.7 --record     ...and, only if 7.2.7 left the driver files
#                                 unchanged, note it in upstream.sha256 as
#                                 checked-through (the updater's preflight and
#                                 the check-up point at newer kernels)
#   refresh.sh --sums             only recompute the PKGBUILD's sha256sums
#
#   --tarball FILE   use this linux-<version>.tar.xz instead of downloading it
#   --kdir DIR       kernel build tree to build against (default: the only
#                    /usr/lib/modules/*/build)
#   --no-build       stop after the diff and the patches
#
# Exit status: 0 when the patches apply without fuzz and the build is free of
# warnings (W=1, plus C=1 when sparse is installed); 1 when not; 2 on bad usage.

set -uo pipefail

PKGDIR=$(readlink -f "$(dirname "$0")")
UPSTREAM_FILES=(nct6775-core.c nct6775-platform.c nct6775-i2c.c nct6775.h lm75.h)
CDN=https://cdn.kernel.org/pub/linux/kernel

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

die() {
  echo "refresh: $*" >&2
  exit 1
}

# The PKGBUILD's source files, in order
pkgbuild_sources() {
  (cd "$PKGDIR" && bash -c 'source ./PKGBUILD >/dev/null 2>&1; printf "%s\n" "${source[@]}"')
}

# Rewrite the sha256sums=( ... ) block of the PKGBUILD from the files as they are
update_sums() {
  local -a files lines
  local f first=1
  mapfile -t files < <(pkgbuild_sources)
  ((${#files[@]})) || die "no source=() in $PKGDIR/PKGBUILD"

  for f in "${files[@]}"; do
    [[ -f $PKGDIR/$f ]] || die "missing source file: $f"
    if ((first)); then
      lines+=("sha256sums=('$(sha256sum "$PKGDIR/$f" | cut -d' ' -f1)'")
      first=0
    else
      lines+=("            '$(sha256sum "$PKGDIR/$f" | cut -d' ' -f1)'")
    fi
  done
  lines[-1]+=")"

  awk -v block="$(printf '%s\n' "${lines[@]}")" '
    /^sha256sums=\(/ { skipping = 1; print block }
    skipping { if (/\)[[:space:]]*$/) skipping = 0; next }
    { print }
  ' "$PKGDIR/PKGBUILD" > "$PKGDIR/PKGBUILD.new" && mv "$PKGDIR/PKGBUILD.new" "$PKGDIR/PKGBUILD"
  echo "PKGBUILD: sha256sums updated for ${#files[@]} files"
}

# The newest release the vendored files are known to match: checked-through,
# else the release they came from
checked_through() {
  local r
  r=$(awk '/^# checked-through:/ { print $3 }' "$PKGDIR/upstream.sha256")
  [[ -n $r ]] || r=$(awk '/^# version:/ { print $3 }' "$PKGDIR/upstream.sha256")
  echo "$r"
}

version="" tarball="" kdir="" update=0 record=0 build=1
while (($#)); do
  case $1 in
    --update) update=1 ;;
    --record) record=1 ;;
    --no-build) build=0 ;;
    --tarball) tarball=${2:-}; shift ;;
    --kdir) kdir=${2:-}; shift ;;
    --sums) update_sums; exit ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) [[ -z $version ]] || usage; version=$1 ;;
  esac
  shift
done
[[ $version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || usage
((update && record)) && usage

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ---- 1. The release tarball, checked against kernel.org's published sums
signature="not checked"
if [[ -z $tarball ]]; then
  base="$CDN/v${version%%.*}.x"
  tarball="$work/linux-$version.tar.xz"
  echo "== downloading linux-$version.tar.xz"
  curl -fsSL -o "$tarball" "$base/linux-$version.tar.xz" || die "download failed: $base/linux-$version.tar.xz"
  curl -fsSL -o "$work/linux-$version.tar.sign" "$base/linux-$version.tar.sign" || true
else
  [[ -f $tarball ]] || die "no such tarball: $tarball"
  [[ -f ${tarball%.xz}.sign ]] && cp "${tarball%.xz}.sign" "$work/linux-$version.tar.sign"
fi
tarball_sha=$(sha256sum "$tarball" | cut -d' ' -f1)

published=$(curl -fsSL "$CDN/v${version%%.*}.x/sha256sums.asc" 2>/dev/null |
  awk -v f="linux-$version.tar.xz" '$2 == f { print $1 }')
if [[ -z $published ]]; then
  echo "== tarball sha256 $tarball_sha (kernel.org's sha256sums.asc not reachable; not compared)"
elif [[ $published == "$tarball_sha" ]]; then
  echo "== tarball sha256 $tarball_sha matches kernel.org's sha256sums.asc"
else
  die "tarball sha256 $tarball_sha does not match kernel.org's $published"
fi

# The signature covers the uncompressed tar; release keys come from kernel.org's WKD
if [[ -f $work/linux-$version.tar.sign ]] && command -v gpg >/dev/null; then
  export GNUPGHOME="$work/gnupg"
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --auto-key-locate clear,wkd --locate-keys torvalds@kernel.org gregkh@kernel.org >/dev/null 2>&1
  if out=$(xz -dc "$tarball" | gpg --batch --status-fd 1 --verify "$work/linux-$version.tar.sign" - 2>/dev/null); then
    signer=$(awk '$2 == "GOODSIG" { $1 = $2 = $3 = ""; sub(/^ +/, ""); print }' <<<"$out")
    signature="good signature by $signer, key $(awk '$2 == "VALIDSIG" { print $3 }' <<<"$out")"
  elif grep -q BADSIG <<<"$out"; then
    die "BAD signature on linux-$version.tar"
  else
    signature="not checked (release key not available)"
  fi
fi
echo "== signature: $signature"

# ---- 2. The driver files from that release
mkdir -p "$work/new"
tar -xJf "$tarball" -C "$work/new" --strip-components=3 \
  "${UPSTREAM_FILES[@]/#/linux-$version/drivers/hwmon/}" || die "the tarball lacks some of: ${UPSTREAM_FILES[*]}"

# ---- 3. What changed upstream since the vendored copy
echo "== upstream changes against the vendored $(awk '/^# version:/ { print $3 }' "$PKGDIR/upstream.sha256")"
changed=0
for f in "${UPSTREAM_FILES[@]}"; do
  if cmp -s "$PKGDIR/$f" "$work/new/$f"; then
    echo "   $f: unchanged"
  else
    changed=1
    echo "   $f: CHANGED ($(diff -u "$PKGDIR/$f" "$work/new/$f" | grep -c '^[-+][^-+]') lines)"
    diff -u --label "vendored/$f" --label "$version/$f" "$PKGDIR/$f" "$work/new/$f" >>"$work/upstream.diff"
  fi
done
if ((changed)); then
  echo "---- upstream diff"
  cat "$work/upstream.diff"
  echo "----"
fi

# ---- 4. The patches, in order, with no fuzz
tree="$work/tree/drivers/hwmon"
mkdir -p "$tree"
cp "${UPSTREAM_FILES[@]/#/$work/new/}" "$tree/"
mapfile -t patches < <(cd "$PKGDIR" && ls [0-9][0-9][0-9][0-9]-*.patch)
for p in "${patches[@]}"; do
  if patch -d "$work/tree" -Np1 --fuzz=0 --no-backup-if-mismatch -i "$PKGDIR/$p" >"$work/patch.log" 2>&1; then
    echo "== $p: applies"
  else
    cat "$work/patch.log"
    die "$p does not apply to $version without fuzz; rebase it by hand"
  fi
done

# ---- 5. Build against the headers, W=1 and sparse; any warning in our files fails
if ((build)); then
  if [[ -z $kdir ]]; then
    kdirs=(/usr/lib/modules/*/build)
    ((${#kdirs[@]} == 1)) && [[ -d ${kdirs[0]} ]] || die "need exactly one /usr/lib/modules/*/build, or --kdir"
    kdir=${kdirs[0]}
  fi
  krel=$(make -s -C "$kdir" kernelrelease 2>/dev/null) || krel=$(basename "$(dirname "$kdir")")
  checker=()
  if command -v sparse >/dev/null; then
    checker=(C=1)
  else
    echo "   (sparse not installed: W=1 only)"
  fi
  cp "$PKGDIR/Makefile" "$tree/"
  echo "== building against $krel: make W=1 ${checker[*]}"
  if ! make -C "$kdir" M="$tree" W=1 "${checker[@]}" modules >"$work/build.log" 2>&1; then
    cat "$work/build.log"
    die "build failed against $krel"
  fi
  # Diagnostics carry file:line; kbuild's version notes do not
  if grep -E ':[0-9]+(:[0-9]+)?: (warning|error)' "$work/build.log"; then
    die "the build against $krel has warnings"
  fi
  for m in nct6775-core nct6775 nct6775-i2c; do
    [[ -f $tree/$m.ko ]] || die "$m.ko was not built"
    echo "   $m.ko: $(modinfo -F vermagic "$tree/$m.ko")"
  done
fi

# ---- 6. Record a release whose driver files are the vendored ones
if ((record)); then
  ((changed == 0)) || die "the driver files changed in $version: read the diff above, then move the package with --update"
  ((build)) || die "--record needs the build too (drop --no-build)"
  checked=$(checked_through)
  if [[ $(printf '%s\n' "$checked" "$version" | sort -V | tail -n 1) != "$version" || $checked == "$version" ]]; then
    echo "== $version is not newer than the recorded $checked: nothing to record"
  else
    if grep -q '^# checked-through:' "$PKGDIR/upstream.sha256"; then
      sed -i "s/^# checked-through:.*/# checked-through: $version/" "$PKGDIR/upstream.sha256"
    else
      sed -i "/^# version:/a # checked-through: $version" "$PKGDIR/upstream.sha256"
    fi
    update_sums
    echo "== recorded: the driver files are unchanged up to $version. Bump pkgrel, run tests/run.sh, then commit."
  fi
fi

# ---- 7. Move the package to the new release
if ((update)); then
  cp "${UPSTREAM_FILES[@]/#/$work/new/}" "$PKGDIR/"
  sig_line="not checked"
  [[ $signature == good* ]] && sig_line="linux-$version.tar.sign, $signature"
  compared="not reachable, not compared"
  [[ -n $published ]] && compared="match"
  {
    echo "# Vendored from Linux $version drivers/hwmon/, byte for byte; the patches are"
    echo "# applied at build time. Check with: sha256sum -c upstream.sha256"
    echo "# checked-through is the newest release whose driver files refresh.sh found"
    echo "# identical to these (refresh.sh <release> --record)."
    echo "#"
    echo "# version: $version"
    echo "# checked-through: $version"
    echo "# tarball: $CDN/v${version%%.*}.x/linux-$version.tar.xz"
    echo "# tarball-sha256: $tarball_sha"
    echo "#   (kernel.org's $CDN/v${version%%.*}.x/sha256sums.asc: $compared)"
    echo "# signature: $sig_line"
    echo "# browse: https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/drivers/hwmon?h=v$version"
    echo "#"
    echo "# lm75.h is not part of the nct6775 driver, but nct6775-core.c includes it."
    (cd "$PKGDIR" && sha256sum "${UPSTREAM_FILES[@]}")
  } >"$PKGDIR/upstream.sha256"

  # dkms.conf wants ^7\.3\. for 7.3.x; sed wants each backslash doubled
  series=$(cut -d. -f1-2 <<<"$version")
  regex="^${series//./\\.}\\."
  sed -i -e "s/^_kver=[^ ]*/_kver=$version/" \
    -e "s/^pkgver=[^ ]*/pkgver=$version.1/" \
    -e "s/^pkgrel=.*/pkgrel=1/" \
    -e "s/from Linux [0-9.]* with/from Linux $version with/" \
    -e "s/every [0-9]*\.[0-9]*\.x kernel/every $series.x kernel/" "$PKGDIR/PKGBUILD"
  sed -i -e "s|^BUILD_EXCLUSIVE_KERNEL=.*|BUILD_EXCLUSIVE_KERNEL=\"${regex//\\/\\\\}\"|" \
    -e "s/are Linux [0-9.]*'s/are Linux $version's/" "$PKGDIR/dkms.conf"
  update_sums
  echo "== moved to $version (pkgver $version.1). Run tests/run.sh, then commit."
fi

echo "== ok: $version"
