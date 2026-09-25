#!/bin/bash
# Rebases each fork's `kitchen` branch onto upstream `quattro` and pushes it.
# Also updates each fork's `quattro` mirror on GitHub.
#
# Usage: sync-upstream.sh [repo...]      (default: omarchy-iso omarchy)
#
# Before rebasing it tags the current `kitchen` as backup/kitchen-<timestamp>-<commit> (local only).
# To undo: git reset --hard backup/kitchen-<timestamp>-<commit> && git push --force-with-lease origin kitchen

set -euo pipefail

UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-quattro}"
KITCHEN_BRANCH="${KITCHEN_BRANCH:-kitchen}"

UMBRELLA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${WORKSPACE:-$(dirname "$UMBRELLA_DIR")}"

if (( $# > 0 )); then
  REPOS=("$@")
else
  REPOS=(omarchy-iso omarchy)
fi

fail() {
  echo "Error: $*" >&2
  exit 1
}

sync_repo() {
  local name=$1
  local dir="$WORKSPACE/$name"
  local local_sha remote_sha backup

  echo
  echo "== $name"

  if [[ ! -d $dir/.git ]]; then
    echo "Not cloned at $dir, skipping. Run setup.sh first."
    return
  fi

  cd "$dir"

  if [[ -d .git/rebase-merge || -d .git/rebase-apply ]]; then
    fail "$name has a rebase in progress. Finish it (git rebase --continue) or abort it (git rebase --abort) first."
  fi

  if ! git diff --quiet || ! git diff --cached --quiet; then
    fail "$name has uncommitted changes. Commit or stash them first."
  fi

  git fetch upstream "$UPSTREAM_BRANCH"
  git fetch origin

  # Keep the fork's mirror of upstream current, so GitHub's compare views stay meaningful.
  git push origin "refs/remotes/upstream/$UPSTREAM_BRANCH:refs/heads/$UPSTREAM_BRANCH"

  git switch --quiet "$KITCHEN_BRANCH"

  # Never rebase over commits that exist only on GitHub (for example, pushed from another machine).
  local_sha=$(git rev-parse "$KITCHEN_BRANCH")
  remote_sha=$(git rev-parse "origin/$KITCHEN_BRANCH")
  if [[ $local_sha != "$remote_sha" ]]; then
    if git merge-base --is-ancestor "$KITCHEN_BRANCH" "origin/$KITCHEN_BRANCH"; then
      echo "Local $KITCHEN_BRANCH is behind GitHub, fast-forwarding."
      git merge --ff-only --quiet "origin/$KITCHEN_BRANCH"
    elif git merge-base --is-ancestor "origin/$KITCHEN_BRANCH" "$KITCHEN_BRANCH"; then
      echo "Local $KITCHEN_BRANCH has unpushed commits; they'll be included."
    else
      fail "$name: local and GitHub $KITCHEN_BRANCH have diverged. Reconcile them by hand first."
    fi
  fi

  if git merge-base --is-ancestor "upstream/$UPSTREAM_BRANCH" "$KITCHEN_BRANCH"; then
    echo "Already on top of upstream $UPSTREAM_BRANCH."
  else
    backup="backup/$KITCHEN_BRANCH-$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short "$KITCHEN_BRANCH")"
    if ! git show-ref --verify --quiet "refs/tags/$backup"; then
      git tag "$backup" "$KITCHEN_BRANCH"
    fi
    echo "Tagged $backup."

    echo "Upstream commits to take in: $(git rev-list --count "$KITCHEN_BRANCH..upstream/$UPSTREAM_BRANCH")"
    echo "Our commits to replay:       $(git rev-list --count "upstream/$UPSTREAM_BRANCH..$KITCHEN_BRANCH")"

    if ! git rebase "upstream/$UPSTREAM_BRANCH"; then
      echo
      echo "The rebase stopped on a conflict in $dir."
      echo "Resolve it, then: git rebase --continue && git push --force-with-lease origin $KITCHEN_BRANCH"
      echo "Or give up and go back: git rebase --abort"
      echo "Then re-run this script for any remaining repos."
      exit 1
    fi
  fi

  git push --force-with-lease origin "$KITCHEN_BRANCH"
}

for repo in "${REPOS[@]}"; do
  sync_repo "$repo"
done

echo
echo "All synced."
