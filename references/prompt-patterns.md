# Prompt Patterns

Use these patterns to shape `<primary-question>` and context packet content.

## review-commit

Primary question examples:

- `Review this commit for correctness, behavior regression, and missing tests.`
- `Find hidden edge cases or API contract breaks in this diff.`

Context packet checklist:

1. Commit hash and intended behavior
2. Diff summary by file/module
3. Existing tests touched or missing
4. Risk surface (state changes, migrations, concurrency, performance)
5. Known uncertainty

## review-diff

Primary question examples:

- `Review this uncommitted diff for correctness, behavior regression, and missing tests.`
- `Find risky edge cases in these staged/working-tree changes.`

Context packet checklist:

1. Scope of working-tree or staged diff
2. Diff summary by file/module
3. Existing tests touched or missing
4. Risk surface (state changes, migrations, concurrency, performance)
5. Known uncertainty

## write-plan

Use one of two intents:

- Plan generation: create a plan from goals and constraints.
- Plan challenge: stress-test an existing draft plan.

Recommended fixed starters:

- `Propose a phased implementation plan ...`
- `Challenge this implementation plan ...`

Primary question examples:

- `Propose a phased implementation plan with rollback and validation checkpoints.`
- `Challenge this implementation plan and propose safer sequencing.`
- `What rollback and validation checkpoints should be added?`

Context packet checklist:

1. Objective and non-goals
2. Constraints (timeline, compatibility, deployment limits)
3. Proposed phases
4. Dependencies and blockers
5. Verification gates per phase

## double-check

Primary question examples:

- `What is most likely wrong or under-validated in this solution?`
- `Try to falsify this conclusion and list the strongest contrary evidence needed.`

Context packet checklist:

1. Candidate solution summary
2. Why this approach was chosen
3. Assumptions
4. Current evidence
5. Remaining unknowns

## Synthesis Rule

Treat Gemini output as advisory input, not final authority. Integrate by tagging each point as `Adopt`, `Investigate`, or `Reject` with one-line reasoning plus explicit source attribution.

Use this compact format:

- `Adopt (source: <Gemini/Codex>)`: ...
- `Investigate (source: <Gemini/Codex>)`: ...
- `Reject (source: <Gemini/Codex/inferred>)`: ...

If no concrete option should be rejected, write `Reject: none`.
