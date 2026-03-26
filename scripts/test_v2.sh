#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$SCRIPT_DIR/second_opinion.sh"
SKILL_FILE="$ROOT_DIR/SKILL.md"

pass=0
fail=0

ok() {
  echo "PASS: $1"
  pass=$((pass + 1))
}

ng() {
  echo "FAIL: $1"
  fail=$((fail + 1))
}

# Test 1: usage and exit code
if "$SCRIPT" >/tmp/so_t1_out.txt 2>/tmp/so_t1_err.txt; then
  ng "usage should fail without args"
else
  rc=$?
  if [[ "$rc" == "64" ]] && grep -q "Usage:" /tmp/so_t1_err.txt; then
    ok "usage returns code 64"
  else
    ng "usage code/message mismatch"
  fi
fi

# Test 2: missing context (no file + no stdin)
if "$SCRIPT" review-commit "q" >/tmp/so_t2_out.txt 2>/tmp/so_t2_err.txt; then
  ng "missing context should fail"
else
  rc=$?
  if [[ "$rc" == "65" ]] && grep -Eq "No context-file and no stdin|context packet is empty" /tmp/so_t2_err.txt; then
    ok "missing context returns code 65"
  else
    ng "missing context code/message mismatch"
  fi
fi

# Test 3: fail-open when gemini command missing
if GEMINI_SECOND_OPINION_CMD="__missing_gemini__" \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') > /tmp/so_t3_out.json 2>/tmp/so_t3_err.txt; then
  if jq -e '.status=="fallback" and .reason=="gemini-unavailable"' /tmp/so_t3_out.json >/dev/null; then
    ok "fail-open fallback on missing gemini"
  else
    ng "fail-open fallback payload invalid"
  fi
else
  ng "fail-open should not return non-zero"
fi

# Test 4: fail-closed when gemini command missing
if GEMINI_SECOND_OPINION_FAILURE_MODE="fail-closed" \
  GEMINI_SECOND_OPINION_CMD="__missing_gemini__" \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') >/tmp/so_t4_out.txt 2>/tmp/so_t4_err.txt; then
  ng "fail-closed should fail"
else
  rc=$?
  if [[ "$rc" == "69" ]]; then
    ok "fail-closed returns code 69"
  else
    ng "fail-closed wrong exit code"
  fi
fi

# Prepare mock gemini commands
mock_ok="$(mktemp)"
cat > "$mock_ok" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"alternate_perspective":"alt","risks":["r1"],"strongest_counterargument":"c","recommendation":"do x","next_verification":["v1"]}
JSON
MOCK
chmod +x "$mock_ok"

mock_slow="$(mktemp)"
cat > "$mock_slow" <<'MOCK'
#!/usr/bin/env bash
sleep 3
cat <<'JSON'
{"alternate_perspective":"alt","risks":["r1"],"strongest_counterargument":"c","recommendation":"do x","next_verification":["v1"]}
JSON
MOCK
chmod +x "$mock_slow"

mock_bad_type="$(mktemp)"
cat > "$mock_bad_type" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"alternate_perspective":"alt","risks":[{"bad":1}],"strongest_counterargument":"c","recommendation":"do x","next_verification":["v1"]}
JSON
MOCK
chmod +x "$mock_bad_type"

mock_log_json="$(mktemp)"
cat > "$mock_log_json" <<'MOCK'
#!/usr/bin/env bash
echo "Loaded cached credentials."
echo "Log: {init}"
cat <<'JSON'
{"alternate_perspective":"alt","risks":["r1"],"strongest_counterargument":"c","recommendation":"do x","next_verification":["v1"]}
JSON
MOCK
chmod +x "$mock_log_json"

mock_tree="$(mktemp)"
cat > "$mock_tree" <<'MOCK'
#!/usr/bin/env bash
(while true; do sleep 1; done) &
echo "$!" > "${GSO_CHILD_PID_FILE:?}"
sleep 120
MOCK
chmod +x "$mock_tree"

# Test 5: success path with valid JSON from mock gemini
if GEMINI_SECOND_OPINION_CMD="$mock_ok" \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') > /tmp/so_t5_out.json 2>/tmp/so_t5_err.txt; then
  if jq -e '.status=="ok" and .opinion.recommendation=="do x" and (.opinion|has("confidence")|not)' /tmp/so_t5_out.json >/dev/null; then
    ok "success path emits validated opinion without confidence"
  else
    ng "success payload invalid"
  fi
else
  ng "success path should return zero"
fi

# Test 5b: review-diff task type works
if GEMINI_SECOND_OPINION_CMD="$mock_ok" \
  "$SCRIPT" review-diff "q" < <(printf 'ctx') > /tmp/so_t5b_out.json 2>/tmp/so_t5b_err.txt; then
  if jq -e '.status=="ok" and .task_type=="review-diff" and .opinion.recommendation=="do x"' /tmp/so_t5b_out.json >/dev/null; then
    ok "review-diff task type works on success path"
  else
    ng "review-diff success payload invalid"
  fi
else
  ng "review-diff success path should return zero"
fi

# Test 6: timeout fallback
if GEMINI_SECOND_OPINION_CMD="$mock_slow" \
  GEMINI_SECOND_OPINION_TIMEOUT_SEC=1 \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') > /tmp/so_t6_out.json 2>/tmp/so_t6_err.txt; then
  if jq -e '.status=="fallback" and .reason=="gemini-timeout"' /tmp/so_t6_out.json >/dev/null; then
    ok "timeout fallback works"
  else
    ng "timeout fallback payload invalid"
  fi
else
  ng "timeout in fail-open should return zero"
fi

# Test 7: deep type validation for risks[]
if GEMINI_SECOND_OPINION_CMD="$mock_bad_type" \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') > /tmp/so_t7_out.json 2>/tmp/so_t7_err.txt; then
  if jq -e '.status=="fallback" and .reason=="invalid-json"' /tmp/so_t7_out.json >/dev/null; then
    ok "deep type validation rejects non-string risks entries"
  else
    ng "deep type validation payload mismatch"
  fi
else
  ng "invalid-json in fail-open should still return zero"
fi

# Test 8: extraction handles leading brace logs and still picks valid JSON
if GEMINI_SECOND_OPINION_CMD="$mock_log_json" \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') > /tmp/so_t8_out.json 2>/tmp/so_t8_err.txt; then
  if jq -e '.status=="ok" and .opinion.recommendation=="do x"' /tmp/so_t8_out.json >/dev/null; then
    ok "robust extraction picks valid JSON object"
  else
    ng "extraction failed with brace-prefixed logs"
  fi
else
  ng "brace-prefixed logs should not break parsing"
fi

# Test 9: timeout cleanup kills process group children
child_pid_file="$(mktemp)"
if GSO_CHILD_PID_FILE="$child_pid_file" \
  GEMINI_SECOND_OPINION_CMD="$mock_tree" \
  GEMINI_SECOND_OPINION_TIMEOUT_SEC=2 \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') > /tmp/so_t9_out.json 2>/tmp/so_t9_err.txt; then
  if ! jq -e '.status=="fallback" and .reason=="gemini-timeout"' /tmp/so_t9_out.json >/dev/null; then
    ng "process-group cleanup timeout payload mismatch"
  elif [[ ! -s "$child_pid_file" ]]; then
    ng "process-group cleanup child pid file missing"
  else
    child_pid="$(cat "$child_pid_file")"
    sleep 1
    if kill -0 "$child_pid" 2>/dev/null; then
      ng "process-group cleanup leaked child process"
      kill "$child_pid" 2>/dev/null || true
    else
      ok "process-group cleanup removes descendants"
    fi
  fi
else
  ng "timeout cleanup probe should return zero in fail-open"
fi

# Test 10: docs reflect single-path workflow
if grep -q "Workflow (v3-lean)" "$SKILL_FILE" && \
  grep -q "second_opinion.sh" "$SKILL_FILE" && \
  grep -q "require_escalated" "$SKILL_FILE" && \
  grep -q "stable prefix approval" "$SKILL_FILE" && \
  grep -q 'do not wrap with `/bin/zsh -lc`' "$SKILL_FILE" && \
  grep -q "export" "$SKILL_FILE" && \
  grep -q "approval-mode=default" "$SKILL_FILE" && \
  grep -q "Path Manifest" "$SKILL_FILE" && \
  grep -q "workspace-scoped" "$SKILL_FILE" && \
  grep -qi '`workdir`' "$SKILL_FILE" && \
  grep -qi "Do not rely on .*symlink" "$SKILL_FILE" && \
  grep -q "Do not paste large file contents" "$SKILL_FILE" && \
  grep -q 'Do not interrupt, restart, or reduce timeout mid-flight.' "$SKILL_FILE" && \
  grep -q 'Never write a bare `Reject` line without a source.' "$SKILL_FILE" && \
  grep -q 'write `Reject: none`' "$SKILL_FILE" && \
  grep -q 'per-item `source` tags' "$SKILL_FILE" && \
  grep -q 'After each cycle, clean `/tmp/so_t\*`, `/tmp/gso_\*`, and `.tmp_skill_review`.' "$SKILL_FILE" && \
  ! grep -q "GEMINI_SECOND_OPINION_LOCK_DIR" "$SKILL_FILE" && \
  ! grep -q "GEMINI_SECOND_OPINION_LOCK_TIMEOUT_SEC" "$SKILL_FILE" && \
  ! grep -q "GEMINI_SECOND_OPINION_LOCK_ORPHAN_GRACE_SEC" "$SKILL_FILE" && \
  ! grep -qi "subagent" "$SKILL_FILE" && \
  ! grep -q "spawn_agent" "$SKILL_FILE" && \
  ! grep -q "parallel_review\\.sh" "$SKILL_FILE"; then
  ok "skill docs preserve lean single-path contract"
else
  ng "skill docs still contain removed subagent path"
fi

# Test 11: lean patch removed fallback async script
if [[ ! -e "$SCRIPT_DIR/parallel_review.sh" ]]; then
  ok "parallel_review.sh removed in v3-lean"
else
  ng "parallel_review.sh should be removed in v3-lean"
fi

# Test 12: subagent wrapper removed
if [[ ! -e "$SCRIPT_DIR/subagent_second_opinion.sh" ]]; then
  ok "subagent_second_opinion.sh removed"
else
  ng "subagent_second_opinion.sh should be removed"
fi

rm -f "$mock_ok" "$mock_slow" "$mock_bad_type" "$mock_log_json" "$mock_tree" "$child_pid_file"

if [[ "$fail" == "0" ]]; then
  echo "All tests passed: $pass"
  exit 0
fi

echo "Tests failed: $fail (passed: $pass)"
exit 1
