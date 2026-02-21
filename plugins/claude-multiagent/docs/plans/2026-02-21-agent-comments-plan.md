# Agent Progress via Beads Comments — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace `.agent-status.d/` file-based agent reporting with `bd comment` on assigned tickets; remove the agents dashboard pane.

**Architecture:** Agents post structured progress comments to their beads ticket every 60s. The beads-tui "Latest Update" column (already polling every 5s) becomes the single view for agent progress. The status monitor agent and `watch-agents.py` curses TUI are removed entirely.

**Tech Stack:** Shell (open-dashboard.sh), Markdown (SKILL.md)

---

### Task 1: Rewrite Agent Reporting Instructions in SKILL.md

**Files:**
- Modify: `plugins/claude-multiagent/skills/multiagent-coordinator/SKILL.md:130-161`

**Step 1: Replace the "Agent Reporting Instructions" section (lines 130-161)**

Replace the entire section from `### Agent Reporting Instructions` through the status file deletion instruction with:

```markdown
### Agent Reporting Instructions

Include verbatim in every agent prompt:

> **Reporting — you MUST follow this.**
>
> Post a progress comment to your assigned beads ticket every 60 seconds using:
>
> ```bash
> bd comment <TICKET_ID> "<update>"
> ```
>
> Each update must follow this structured format:
>
> ```
> [<step>/<total>] <current activity>
> Done: <what you completed since last update>
> Doing: <what you're working on now>
> Blockers: <anything preventing progress, or "none">
> ETA: <your best estimate for completion>
> Files: <files created or modified so far>
> ```
>
> Example:
>
> ```bash
> bd comment proj-abc "[2/5] Writing tests
> Done: Implemented auth middleware
> Doing: Unit tests for login flow
> Blockers: none
> ETA: ~3 min
> Files: src/auth.ts, src/auth.test.ts"
> ```
>
> If you've been stuck on the same sub-task for more than 3 minutes, say so explicitly in the Blockers field.
>
> When you're done, post a final comment with: summary of all changes, files modified, and test results.
```

**Step 2: Verify the edit**

Read back lines 130-165 of the file and confirm the new section is correct.

**Step 3: Commit**

```bash
git add plugins/claude-multiagent/skills/multiagent-coordinator/SKILL.md
git commit -m "feat: replace agent status files with bd comment reporting"
```

---

### Task 2: Remove Status Monitor Agent from SKILL.md

**Files:**
- Modify: `plugins/claude-multiagent/skills/multiagent-coordinator/SKILL.md:163-246`

**Step 1: Delete the entire "Status Monitor Agent" section (lines 163-246)**

Remove everything from `### Status Monitor Agent (CRITICAL — must always be running)` through the closing `> - When you receive a shutdown message, approve it and exit immediately.` line.

**Step 2: Commit**

```bash
git add plugins/claude-multiagent/skills/multiagent-coordinator/SKILL.md
git commit -m "feat: remove status monitor agent section"
```

---

### Task 3: Clean up remaining `.agent-status.d/` references in SKILL.md

**Files:**
- Modify: `plugins/claude-multiagent/skills/multiagent-coordinator/SKILL.md`

There are several remaining references to `.agent-status.d/` that need updating:

**Step 1: Update Rule Zero (line 14)**

Change:
```
...or making any file-system change that is not inside `.agent-status.d/` or a git merge operation.
```
To:
```
...or making any file-system change that is not a git merge operation.
```

**Step 2: Update Sub-Agents section (line 81)**

Remove:
```
- **Before first dispatch:** Ensure `.agent-status.d/` directory exists (create it if needed). On request, read files in `.agent-status.d/` to provide a verbal status table to the user.
```

Replace with:
```
- **Before first dispatch:** Verify beads are initialized (`bd list`) and the dashboard is open.
```

**Step 3: Update course-correction (line 128)**

Change:
```
- **Course-correction:** Use `SendMessage` to nudge stuck agents (e.g., "check git history" or "focus on file X"). When course-correcting, also: (1) create a bd ticket for the additional work, and (2) update the agent's status file in `.agent-status.d/<agent-name>` immediately to reflect the new scope.
```
To:
```
- **Course-correction:** Use `SendMessage` to nudge stuck agents (e.g., "check git history" or "focus on file X"). When course-correcting, also create a bd ticket for the additional work if needed.
```

**Step 4: Update merging cleanup step 3 (line 259)**

Remove line:
```
3. `rm -f .agent-status.d/<agent-name>`
```

And renumber remaining steps (old step 4 becomes 3, old step 5 becomes 4).

**Step 5: Update Dashboard description (line 282)**

Change:
```
Open Zellij panes showing agent status, open tickets, and deploy status alongside your Claude session.
```
To:
```
Open Zellij panes showing open tickets and deploy status alongside your Claude session.
```

**Step 6: Commit**

```bash
git add plugins/claude-multiagent/skills/multiagent-coordinator/SKILL.md
git commit -m "feat: remove all .agent-status.d references from coordinator prompt"
```

---

### Task 4: Remove agents pane from dashboard script

**Files:**
- Modify: `plugins/claude-multiagent/scripts/open-dashboard.sh`

**Step 1: Remove agents pane detection (line 205)**

Delete:
```bash
has_agents=$(has_dashboard_pane "$focused_tab" "dashboard-agents" "watch-agents.py" "$PROJECT_DIR")
```

**Step 2: Remove agents pane from "all present" check (line 210)**

Delete:
```bash
[[ "$has_agents" -eq 0 ]] && all_present=false
```

**Step 3: Remove agents pane creation block (lines 295-308)**

Delete the entire `if [[ "$has_agents" -eq 0 ]]` block including the inner if/else for right pane direction.

**Step 4: Update the layout diagram comment (lines 224-233)**

Replace with:
```bash
#   ┌──────────────┬────────────────┐
#   │              │  watch-beads   │
#   │   Claude     ├────────────────┤
#   │              │  watch-deploys │
#   └──────────────┴────────────────┘
```

**Step 5: Update script header comment (line 2)**

Change:
```bash
# Open Zellij dashboard panes for beads (tickets), agent status, and deploy watch.
```
To:
```bash
# Open Zellij dashboard panes for beads (tickets) and deploy watch.
```

**Step 6: Commit**

```bash
git add plugins/claude-multiagent/scripts/open-dashboard.sh
git commit -m "feat: remove agents pane from dashboard layout"
```

---

### Task 5: Delete watch-agents.py

**Files:**
- Delete: `plugins/claude-multiagent/scripts/watch-agents.py`

**Step 1: Delete the file**

```bash
git rm plugins/claude-multiagent/scripts/watch-agents.py
```

**Step 2: Commit**

```bash
git commit -m "feat: remove watch-agents.py (replaced by beads-tui comments)"
```

---

### Task 6: Verify and squash

**Step 1: Read the final SKILL.md and confirm coherence**

Read through the full file. Check that:
- No dangling references to `.agent-status.d/`
- No references to `watch-agents.py`
- No references to the status monitor agent
- The reporting instructions use `bd comment`
- Line numbers and section flow make sense

**Step 2: Read open-dashboard.sh and confirm the agents pane is fully removed**

Check that:
- No `has_agents` variable
- No `watch-agents.py` reference
- Layout diagram is updated
- Deploy pane creation logic still works (it should now split the beads pane downward)

**Step 3: Confirm watch-agents.py is deleted**

```bash
ls plugins/claude-multiagent/scripts/watch-agents.py 2>&1  # should not exist
```
