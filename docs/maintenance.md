# Repository and ticket maintenance

Keep Linear as the issue source of truth, preserve completed issue history, and remove only branches whose work is confirmed merged. For personal app installation and updates, see [personal installation](personal-installation.md).

## Linear archiving

Do not delete tickets to clean up the project. Completed work stays linked to its merged PR and actual test results. Keep backlog, blocked and in-progress issues open until their acceptance criteria are met.

Linear's [current archive documentation](https://linear.app/docs/delete-archive-issues), checked on 2026-11-18, describes automatic archiving with no manual archive option. Team Settings → Automations controls the inactivity period. Changes normally take effect on the next run, typically within 24 hours. Closed issues in unfinished projects or active cycles are not eligible until the parent project/cycle has also completed the required period. Open parents/sub-issues and recent activity can also delay archiving.

Chunky is still an active project. Do not mark it completed merely to archive its Done issues. If work is eventually organized into completed phase projects, close each phase only after its remaining work is genuinely complete; then let the configured archive policy run. Moving current issues or restructuring the project should be an explicit planning decision.

The Free plan currently advertises 250 issues on [Linear's pricing page](https://linear.app/pricing). Verify the workspace's actual issue usage in Settings → Administration → Billing; a project's issue count alone does not establish remaining workspace capacity. Do not report freed capacity until archive timestamps and the actual usage counter confirm it.

Archived history is available through the team's Archives page (`G`, then `X`) and can be restored. Do not confuse deleting an issue with archiving it: deleted issues become permanently unrecoverable after Linear's retention period.

## Cleanup snapshot: 2026-11-18

Before the maintenance follow-up ticket was created, the Chunky project contained 120 non-archived issues: 106 Done, one Canceled, nine Backlog and four In Progress. No archived issues were returned. This is a dated project inventory, not a billing measurement.

The connected Linear tools expose no issue-archive or team-automation mutation. This session also has no desktop/browser interaction tool for changing those settings. Therefore no issue was archived or deleted and no quota reduction is claimed. An active project also prevents the requested automatic archive under the documented rules.

Open work at the inventory point:

| Area | Issues |
| --- | --- |
| Personal app/runtime updates | PER-240, PER-241 |
| Dependency migrations awaiting support | PER-223, PER-226 |
| Owner license decision | PER-60 |
| Hardware and deployment acceptance/setup | PER-40, PER-41, PER-42, PER-53, PER-106 |
| Other-session research/benchmark acceptance | PER-181, PER-182 |
| Optional large-file uploads | PER-107 |

Eight clean local branch/worktree pairs were removed after their exact head commits matched merged PRs: `codex/per-237-interface-modes` (#100), `codex/per-233-colima` and `codex/per-233-independent-review` (#101), `codex/per-239-install` (#102), `codex/per-242-personal-guide` (#103), `codex/per-243-native-ux` (#104), `codex/per-249-qdrant-integration` (#105), and `codex/per-245-qdrant-fixes` (#106).

The remaining remote `cursor/per-128-verify-worker-3b47` branch was removed only after its exact head matched merged PR #40. Other recently merged feature branches had already been removed remotely. Five dirty worktrees were preserved: `chunky-per185-review`, `chunky-per200`, `chunky-per237-screenshots`, `chunky-per52-review` and `chunky-per52-web`. Older unverified review/development branches were also retained.

## Repeatable branch cleanup

1. Fetch and prune remote tracking refs, then list open PRs, local branches and worktrees.
2. Check each candidate's current head and working-tree status immediately before removal. Preserve modified/untracked work and branches whose merge cannot be established.
3. Confirm the exact PR head is merged. Squash merges do not make the original feature head an ancestor of main, so ancestry alone cannot identify them reliably.
4. Remove a clean worktree using ordinary `git worktree remove`; if it refuses, inspect the reason rather than forcing removal. Delete its verified merged branch afterward. For remote deletion, verify the current remote head still matches the merged PR.
5. Finish by checking main's status, remaining open PRs and remote refs. Never delete main, reset another session's checkout, or remove database volumes, datasets, credentials or user settings during repository cleanup.

Current shipped features are documented in [interface modes](interface-modes.md) and [Qdrant client provenance](qdrant-client.md). The [native UX audit](native-ux-audit.md) retains historical observations and distinguishes the implemented follow-up from remaining ideas.
