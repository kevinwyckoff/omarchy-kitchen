# shellcheck shell=bash
# Minimal assertions for the shell tests. Source it; call finish at the end.
# result and expect read kitchen-checkup's levels, checks and messages arrays.
# shellcheck disable=SC2154

passed=0
failed=0

ok() {
  passed=$((passed + 1))
}

not_ok() {
  failed=$((failed + 1))
  printf 'not ok - %s\n' "$*" >&2
}

# The last result recorded for a check, as "LEVEL message".
result() {
  local i out=""
  for i in "${!checks[@]}"; do
    [[ ${checks[$i]} == "$1" ]] && out="${levels[$i]} ${messages[$i]}"
  done
  printf '%s' "$out"
}

# expect NAME CHECK LEVEL [SUBSTRING...]: CHECK's last result has LEVEL and
# contains every SUBSTRING.
expect() {
  local name=$1 check=$2 level=$3 r s
  shift 3
  r=$(result "$check")
  if [[ -z $r ]]; then
    not_ok "$name: no result for '$check' (have: ${checks[*]})"
    return
  fi
  if [[ ${r%% *} != "$level" ]]; then
    not_ok "$name: '$check' is [$r], expected $level"
    return
  fi
  for s in "$@"; do
    if [[ $r != *"$s"* ]]; then
      not_ok "$name: '$check' lacks '$s': [$r]"
      return
    fi
  done
  ok
}

# expect_none NAME CHECK: CHECK recorded nothing.
expect_none() {
  local r
  r=$(result "$2")
  if [[ -n $r ]]; then
    not_ok "$1: expected no '$2' result, got [$r]"
  else
    ok
  fi
}

# expect_eq NAME GOT WANT
expect_eq() {
  if [[ $2 == "$3" ]]; then
    ok
  else
    not_ok "$1: got [$2], want [$3]"
  fi
}

# expect_has NAME HAYSTACK NEEDLE
expect_has() {
  if [[ $2 == *"$3"* ]]; then
    ok
  else
    not_ok "$1: [$2] lacks [$3]"
  fi
}

finish() {
  printf '%s: %d passed, %d failed\n' "$1" "$passed" "$failed"
  ((failed == 0))
}
