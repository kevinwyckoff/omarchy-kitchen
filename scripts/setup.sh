#!/bin/bash
# Sets up the Kitchen workspace next to this repo:
#   - renames the umbrella repo on GitHub, if it still has its old name
#   - forks omacom/omarchy and omacom/omarchy-iso, clones them, adds an `upstream` remote,
#     and creates the `kitchen` branch from upstream `quattro`
#   - clones omacom/omarchy-pkgs read-only (needed for local ISO builds)
#   - makes the first commit of this repo and pushes it, if that hasn't happened yet
#
# Safe to re-run: every step checks whether it's already done.
# DRY_RUN=1 prints what would change without changing anything.

set -euo pipefail

UPSTREAM_ORG="${UPSTREAM_ORG:-omacom}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-quattro}"
KITCHEN_BRANCH="${KITCHEN_BRANCH:-kitchen}"
UMBRELLA_OLD="${UMBRELLA_OLD:-Omarchy-The-Kitchen-is-Open-}"
UMBRELLA_NEW="${UMBRELLA_NEW:-omarchy-kitchen}"
GITHUB_URL="${GITHUB_URL:-https://github.com}"
DRY_RUN="${DRY_RUN:-0}"

UMBRELLA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${WORKSPACE:-$(dirname "$UMBRELLA_DIR")}"

run() {
  echo "+ $*"
  if (( DRY_RUN == 0 )); then
    "$@"
  fi
}

step() {
  echo
  echo "== $*"
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

repo_exists() {
  gh repo view "$1" >/dev/null 2>&1
}

check_requirements() {
  command -v git >/dev/null || fail "git is not installed"
  command -v gh >/dev/null || fail "the GitHub CLI (gh) is not installed. On Arch: sudo pacman -S github-cli"
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in. Run: gh auth login"

  if [[ -z $(git config user.name) || -z $(git config user.email) ]]; then
    fail "git has no identity. Run: git config --global user.name \"…\" and git config --global user.email \"…\""
  fi

  OWNER="${OWNER:-$(gh api user --jq .login)}"
  echo "GitHub account: $OWNER"
  echo "Workspace:      $WORKSPACE"
  if (( DRY_RUN == 1 )); then
    echo "Dry run: nothing will be changed."
  fi
}

rename_umbrella() {
  step "Umbrella repo: $OWNER/$UMBRELLA_NEW"

  if repo_exists "$OWNER/$UMBRELLA_NEW"; then
    echo "Already named $UMBRELLA_NEW."
  elif repo_exists "$OWNER/$UMBRELLA_OLD"; then
    run gh repo rename "$UMBRELLA_NEW" -R "$OWNER/$UMBRELLA_OLD" --yes
  else
    run gh repo create "$OWNER/$UMBRELLA_NEW" --public --description "Omarchy: The Kitchen Is Open. Plans and workspace for the installer fork."
  fi
}

# GitHub creates forks in the background, so a clone right after `gh repo fork` can briefly fail.
clone_with_retry() {
  local url=$1
  local dir=$2
  local attempt

  if (( DRY_RUN == 1 )); then
    run git clone "$url" "$dir"
    return
  fi

  for attempt in 1 2 3 4 5 6; do
    echo "+ git clone $url $dir"
    if git clone "$url" "$dir"; then
      return
    fi
    echo "Clone failed (attempt $attempt of 6); GitHub may still be creating the fork. Retrying in 10 seconds."
    sleep 10
  done

  fail "could not clone $url"
}

# A repo with the fork's name that isn't a fork of upstream would make `gh repo fork` pick a
# different name silently, so stop and say so instead.
check_is_fork() {
  local name=$1
  local parent

  parent=$(gh repo view "$OWNER/$name" --json parent --jq '.parent | if . then "\(.owner.login)/\(.name)" else "" end')
  if [[ $parent != "$UPSTREAM_ORG/$name" ]]; then
    fail "$OWNER/$name exists but is not a fork of $UPSTREAM_ORG/$name (parent: ${parent:-none}). Rename or delete it, then re-run."
  fi
}

setup_fork() {
  local name=$1
  local dir="$WORKSPACE/$name"

  step "Fork: $OWNER/$name (from $UPSTREAM_ORG/$name)"

  if repo_exists "$OWNER/$name"; then
    check_is_fork "$name"
    echo "Fork exists."
  else
    run gh repo fork "$UPSTREAM_ORG/$name" --clone=false --default-branch-only
  fi

  if [[ -d $dir/.git ]]; then
    echo "Already cloned at $dir."
  else
    clone_with_retry "$GITHUB_URL/$OWNER/$name.git" "$dir"
  fi

  if (( DRY_RUN == 1 )) && [[ ! -d $dir/.git ]]; then
    echo "+ (then: add upstream remote, create $KITCHEN_BRANCH from upstream/$UPSTREAM_BRANCH, push, set as default branch)"
    return
  fi

  if git -C "$dir" remote get-url upstream >/dev/null 2>&1; then
    echo "Remote upstream exists."
  else
    # Track only the upstream branch we follow; upstream has over a hundred topic branches.
    run git -C "$dir" remote add -t "$UPSTREAM_BRANCH" upstream "$GITHUB_URL/$UPSTREAM_ORG/$name.git"
  fi

  run git -C "$dir" config rerere.enabled true
  run git -C "$dir" config rerere.autoupdate true
  run git -C "$dir" fetch upstream

  if git -C "$dir" ls-remote --exit-code --heads origin "$KITCHEN_BRANCH" >/dev/null 2>&1; then
    echo "Branch $KITCHEN_BRANCH exists on the fork."
    if ! git -C "$dir" show-ref --verify --quiet "refs/heads/$KITCHEN_BRANCH"; then
      run git -C "$dir" fetch origin "$KITCHEN_BRANCH"
      run git -C "$dir" switch --track -c "$KITCHEN_BRANCH" "origin/$KITCHEN_BRANCH"
    fi
  else
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$KITCHEN_BRANCH"; then
      run git -C "$dir" switch "$KITCHEN_BRANCH"
    else
      run git -C "$dir" switch -c "$KITCHEN_BRANCH" "upstream/$UPSTREAM_BRANCH"
    fi
    run git -C "$dir" push -u origin "$KITCHEN_BRANCH"
  fi

  run gh repo edit "$OWNER/$name" --default-branch "$KITCHEN_BRANCH" \
    --description "Kitchen fork of $UPSTREAM_ORG/$name. Plans and workflow: $OWNER/$UMBRELLA_NEW" \
    --homepage "$GITHUB_URL/$OWNER/$UMBRELLA_NEW"
}

clone_pkgs() {
  local dir="$WORKSPACE/omarchy-pkgs"

  step "Read-only clone: $UPSTREAM_ORG/omarchy-pkgs"

  if [[ -d $dir/.git ]]; then
    echo "Already cloned at $dir."
  else
    run git clone "$GITHUB_URL/$UPSTREAM_ORG/omarchy-pkgs.git" "$dir"
  fi
}

push_umbrella() {
  local url="$GITHUB_URL/$OWNER/$UMBRELLA_NEW.git"

  step "First push of this repo"

  cd "$UMBRELLA_DIR"

  if [[ -d .git ]]; then
    echo "Already a git repo."
  else
    run git init -b main
  fi

  if git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    echo "Already has commits."
  else
    run git add -A
    run git commit -m "Start the Kitchen: specs, decisions, workflow, workspace scripts"
  fi

  if git remote get-url origin >/dev/null 2>&1; then
    run git remote set-url origin "$url"
  else
    run git remote add origin "$url"
  fi

  run git push -u origin main
}

check_requirements
rename_umbrella
setup_fork omarchy-iso
setup_fork omarchy
clone_pkgs
push_umbrella

step "Done"
echo "Workspace: $WORKSPACE"
echo "Build an ISO: cd $WORKSPACE/omarchy-iso && ./bin/omarchy-iso-make --local-source ../omarchy ../omarchy-pkgs"
