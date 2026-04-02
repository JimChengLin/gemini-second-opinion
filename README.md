# Gemini Review Codex Skill

Lean Codex skill for getting a Gemini second opinion on hard tasks.

## What It Does

- Uses `scripts/second_opinion.sh` as the single execution path.
- Supports `review-commit`, `review-diff`, `write-plan`, and `double-check` task types.
- Returns normalized JSON (`ok` or `fallback`) for reliable downstream decisions.
- Requires `jq` and `perl` at runtime.

## Repository Layout

- `SKILL.md`: skill instructions and workflow.
- `scripts/second_opinion.sh`: main second-opinion runner.
- `scripts/test.sh`: regression tests.
- `references/prompt-patterns.md`: prompt/context patterns.
- `agents/openai.yaml`: skill metadata.

## Quick Start

Review a commit:

```bash
git show <commit_sha> > /tmp/review_ctx.txt
scripts/second_opinion.sh \
  review-commit \
  "Find correctness and regression risks in this commit" \
  /tmp/review_ctx.txt
```

Review uncommitted diff:

```bash
git diff --no-color --unified=0 > /tmp/review_ctx.txt
scripts/second_opinion.sh \
  review-diff \
  "Find correctness and regression risks in this diff" \
  /tmp/review_ctx.txt
```

Run with stdin:

```bash
cat /tmp/solution_summary.txt | \
scripts/second_opinion.sh \
  double-check \
  "What is most likely wrong or under-validated?"
```

## Key Environment Variables

- `GEMINI_SECOND_OPINION_MODEL` (default: unset, Gemini CLI chooses model)
- `GEMINI_SECOND_OPINION_TIMEOUT_SEC` (default: `300`)
- `GEMINI_SECOND_OPINION_MAX_CONTEXT_BYTES` (default: `300000`)
- `GEMINI_SECOND_OPINION_FAILURE_MODE` (`fail-open`/`fail-closed`, default: `fail-open`)
- `GEMINI_SECOND_OPINION_CMD` (default: `gemini`)
- `GEMINI_SECOND_OPINION_APPROVAL_MODE` (default: `default`)

## Development

Run tests:

```bash
scripts/test.sh
```

Cleanup after local runs:

```bash
setopt nonomatch; rm -f /tmp/so_t* /tmp/gso_* 2>/dev/null || true
```
