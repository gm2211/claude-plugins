# Agent Instructions

## Issue tracking

Tasks are GitHub Issues, managed with the `gh` CLI:

```bash
gh issue list                                       # Find open work
gh issue create --title "..." --body "..."          # File a task
gh issue close <n> --comment "Completed in #<pr>"   # Complete work
```

For follow-up work discovered along the way, file a new issue and reference the parent issue number (for example "Follow-up to #12") in the body.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create GitHub Issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished issues, comment on in-progress ones
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

Repo-specific: if you add plugins back to this repo, bump the version in `.claude-plugin/marketplace.json` on every commit that changes plugin files.

## Worktree Convention

When the coordinator dispatches you with REPO_ROOT and EPIC_BRANCH:
1. `cd $REPO_ROOT`
2. `git worktree add .worktrees/${EPIC_BRANCH}--<your-task-slug> -b ${EPIC_BRANCH}--<your-task-slug>`
3. `cd .worktrees/${EPIC_BRANCH}--<your-task-slug>`
4. Do all work in this worktree
5. Commit and push your branch when done
