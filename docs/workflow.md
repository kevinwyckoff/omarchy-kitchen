# Workflow

How changes move through the forks, how the forks keep up with upstream, and how changes go back upstream.

## Branches in each fork

| Branch | What it is | Rules |
|---|---|---|
| `quattro` | Mirror of upstream's `quattro` | Never commit to it. `sync-upstream.sh` updates it. |
| `kitchen` | Upstream plus our changes, as a linear stack of commits | Default branch. Rebased onto upstream by `sync-upstream.sh`. |
| topic branches | One per piece of work, for example `wipe-summary` | Merged into `kitchen` with a rebase, so `kitchen` stays linear |

**Where a topic branch starts:**
- **From `quattro`** if the change could go upstream. That's most of Phases 0 and 1 (wipe summary, picker fixes, visible encryption choice, `install.toml`). The branch then works as an upstream PR as-is.
- **From `kitchen`** if the change only makes sense in the fork, or depends on other fork-only changes.

Keep upstreamable commits near the bottom of the `kitchen` stack. They rebase with fewer conflicts there, and they're easier to lift out.

## Keeping up with upstream

```bash
./omarchy-kitchen/scripts/sync-upstream.sh
```

For each fork, the script:
1. refuses to run if the working tree has uncommitted changes, or if local and remote `kitchen` have diverged
2. fetches upstream and updates the fork's `quattro` mirror on GitHub
3. tags the current `kitchen` as `backup/kitchen-<timestamp>-<commit>` (local only)
4. rebases `kitchen` onto upstream's `quattro`
5. pushes with `--force-with-lease`

If the rebase stops on a conflict, resolve it, run `git rebase --continue`, then `git push --force-with-lease origin kitchen`. `git rerere` is on in both forks, so a conflict you resolve once gets resolved the same way next time.

To undo a sync: `git reset --hard backup/kitchen-<timestamp>-<commit>`, then push with `--force-with-lease`.

**How often:** weekly is a good default while upstream is in alpha. Small, frequent rebases are much easier than large, rare ones.

## Sending a change upstream

1. Make sure the topic branch starts from `quattro` and contains only that change.
2. Rebase it onto the latest upstream `quattro`.
3. Follow the upstream repo's own `AGENTS.md` and `agents/skills/` guides, and run its tests.
4. Open the PR against `omacom/<repo>`, base `quattro`.

Once upstream merges it, the next `sync-upstream.sh` run drops the now-duplicate commit from `kitchen` automatically.

## Changing the plan

- The spec in `plans/` is the source of truth for what gets built. When code needs something the spec doesn't say, update the spec in the same change.
- When a decision changes, add an entry to `docs/decisions.md`.
- Keep the v1 full spec as it is. It's the reference for deferred work, not a live plan.

## Commit messages

Follow upstream's style in each fork. When a commit implements part of the spec, name the section in the body, for example `Spec: §2.3 picker fixes`.
