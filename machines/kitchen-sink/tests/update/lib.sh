# shellcheck shell=bash
# shellcheck disable=SC2001 # sed runs over multi-line text
# Assertion helpers for the kitchen-update tests. Sourced, never run.

pass=0
failed=0

t_ok() {
  echo "PASS  $1"
  pass=$((pass + 1))
}

t_fail() {
  echo "FAIL  $1"
  [[ -z ${2:-} ]] || sed 's/^/        | /' <<<"$2" | head -n 40
  failed=$((failed + 1))
}

# expect NAME CMD...: passes when CMD succeeds.
expect() {
  local name=$1
  shift
  if "$@"; then t_ok "$name"; else t_fail "$name"; fi
}

# expect_eq NAME WANT GOT
expect_eq() {
  if [[ $3 == "$2" ]]; then t_ok "$1"; else t_fail "$1" "wanted: [$2]"$'\n'"got:    [$3]"; fi
}

# expect_rc NAME WANT RC OUTPUT: compare an exit status captured by the caller.
expect_rc() {
  if (( $3 == $2 )); then t_ok "$1"; else t_fail "$1 (exit $3, wanted $2)" "$4"; fi
}

# expect_match NAME ERE TEXT / expect_nomatch NAME ERE TEXT
expect_match() {
  if grep -qE -- "$2" <<<"$3"; then t_ok "$1"; else t_fail "$1 (no line matches /$2/)" "$3"; fi
}
expect_nomatch() {
  if grep -qE -- "$2" <<<"$3"; then t_fail "$1 (a line matches /$2/)" "$3"; else t_ok "$1"; fi
}

t_summary() {
  echo "---- $1: $pass passed, $failed failed"
  (( failed == 0 ))
}
