---
description: Implement a complex feature using spec-driven TDD with self-review, codex review, and specify verification loops
argument-hint: Feature description or area to work on
---

# Build Feature

You are implementing a feature using a rigorous, spec-driven development process. Follow every phase in order. Do not skip phases.

Initial request: $ARGUMENTS

---

## Phase 1: Feature Definition

**Goal**: Collaborate with the user to produce a clear, complete feature definition.

**Actions**:
1. If the feature is unclear or underspecified, ask the user targeted questions:
   - What problem does this solve?
   - What are the inputs, outputs, and side effects?
   - What are the edge cases and error conditions?
   - Are there constraints (performance, compatibility, security)?
2. Summarize the feature definition back to the user. Get explicit confirmation before proceeding.
3. Create a task list tracking all phases of this workflow.

---

## Phase 2: Plan

**Goal**: Produce a concrete implementation plan that includes spec changes and a testing strategy.

**Actions**:
1. Explore the codebase to understand relevant existing code, patterns, and architecture. Use agents for parallel exploration if the feature touches multiple areas.
2. Read all key files identified during exploration.
3. Draft a plan with these **mandatory** sections:

   ### a. Spec Changes (REQUIRED)
   - Identify which sections of the product spec (`specify.spec.yaml` or the relevant spec file) need to be added or modified to describe the new feature.
   - List the specific properties, narratives, or requirements to add.

   ### b. Testing Plan
   - List the unit tests, integration tests, or e2e tests to write.
   - Identify what test infrastructure (fixtures, mocks, helpers) is needed.
   - Map tests to requirements from the spec.

   ### c. Implementation Steps
   - Break the implementation into ordered, incremental steps.
   - Each step should be small enough to test independently.

4. Present the plan to the user. **Wait for explicit approval before proceeding.**

---

## Phase 3: Spec Update (REQUIRED)

**Goal**: Update the product spec to describe the new feature BEFORE writing any implementation code.

**Actions**:
1. Run `sp spec guide` to get the authoring guide — use it as reference for spec syntax and patterns.
2. Read the current spec file to understand its structure.
3. Modify the spec file to add the new feature's requirements, properties, and behavioral descriptions.
4. Lint the spec to catch structural errors: `sp spec lint --spec <spec-file>`
5. This is the "red" in red-green — the spec now describes behavior that doesn't exist yet.

---

## Phase 4: Red-Green TDD Implementation

**Goal**: Implement the feature using red-green TDD.

**LOOP**: For each implementation step from the plan:

### 4a. Red — Write Failing Tests
1. Write tests that cover the requirement for this step.
2. Run tests to confirm they fail: `npm test` (or the project's test command).
3. If tests pass unexpectedly, the test isn't testing the right thing — fix it.

### 4b. Green — Write Implementation
1. Write the minimum code to make the failing tests pass.
2. Run tests to confirm they pass.
3. If tests fail, fix the implementation (not the tests, unless the test was wrong).

### 4c. Refactor (light)
1. Clean up only what you just wrote — no drive-by refactors.
2. Run tests again to confirm nothing broke.

---

## Phase 5: Self-Review Loop

**Goal**: Catch issues before external review.

**LOOP**:
1. Re-read all code you wrote or modified, plus surrounding context (neighboring functions, callers, tests).
2. Check for:
   - Logic errors, off-by-one, missing edge cases
   - Security issues (injection, XSS, etc.)
   - Violations of existing code conventions
   - Dead code, unnecessary complexity
   - Missing error handling at system boundaries
3. If you find something to fix → fix it, then **restart this loop from step 1**.
4. If clean → proceed to Phase 6.

---

## Phase 6: Codex Review

**Goal**: Get an independent review from a different model to catch blind spots.

**Prerequisites**: This phase requires the `codex` MCP server. If it's not available, install it:
```
claude mcp add codex -s user -- codex -m gpt-5.4 -c model_reasoning_effort="high" mcp-server
```

**Actions**:
1. Prepare a review request for Codex. Include:
   - A diff or summary of all changes (use `git diff`)
   - The feature description and relevant spec sections
   - The test results
   - **Do NOT include your own assessment or opinions** — let Codex form its own view.
2. Launch a code-reviewer agent (subagent) with the review context. Ask it to:
   - Review for correctness, security, performance, and maintainability
   - Check that tests cover the stated requirements
   - Flag anything suspicious or non-idiomatic
3. Review the agent's findings.
4. If there are issues to fix → fix them, then **restart Phase 6 from step 1** (get a fresh review).
5. If clean → proceed to Phase 7.

---

## Phase 7: Specify Verification

**Goal**: Verify the implementation against the product spec using the specify agent.

**Actions**:
1. Determine the verification mode based on what the feature touches:
   - **Live web app**: Start the app locally (e.g., `npm start`), note the URL/port, then run:
     ```
     sp verify --spec <spec-file> --url <local-url>
     ```
   - **CLI feature**: If the spec has a `cli` section, just run:
     ```
     sp verify --spec <spec-file>
     ```
     (CLI verification is auto-detected)
   - **Offline data validation**: If you have captured data, run:
     ```
     sp verify --spec <spec-file> --capture <capture-dir>
     ```
2. Use `--output <dir>` to save the report for inspection.
3. Review the verify report. Look at both pass/fail status and exit codes (0=success, 1=assertion failure, 2=all untested).
4. If specify reports failures → fix the issues, then **restart Phase 7 from step 1**.
5. If specify passes → proceed to Phase 8.

---

## Phase 8: Final Gate

**Goal**: Run all deterministic tests one final time and commit.

**Actions**:
1. Run the full test suite: `npm test`
2. If tests fail → go back to **Phase 4** (TDD loop) to fix the regression, then re-run Phases 5-7.
3. If tests pass:
   - Stage and commit all changes with a descriptive commit message.
   - Ask the user: **"All tests pass and the spec is verified. Want me to push?"**
   - Only push if the user confirms.

---

## Rules

- **Never skip the spec update.** The spec is the source of truth.
- **Never skip the self-review loop.** Catch your own mistakes before wasting external review cycles.
- **Never influence the codex reviewer.** Present facts, not opinions.
- **Never force-push or push without asking.**
- **Track progress** using tasks throughout. Mark each phase complete as you finish it.
- **If stuck**, ask the user rather than guessing or brute-forcing.
