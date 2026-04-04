#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$SCRIPT_DIR/second_opinion.sh"
SKILL_FILE="$ROOT_DIR/SKILL.md"

pass=0
fail=0

# Most tests verify non-sandbox behavior; Test 7 sets sandbox env explicitly.
unset CODEX_SANDBOX_NETWORK_DISABLED 2>/dev/null || true

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
cat <<'JSONL'
{"type":"init","timestamp":"2026-03-30T10:00:00.000Z","session_id":"s-ok","model":"gemini-3-pro"}
{"type":"message","timestamp":"2026-03-30T10:00:01.000Z","role":"assistant","content":"{\"risks\":[\"r1\"],\"strongest_counterargument\":\"c\",\"recommendation\":\"do x\",\"next_verification\":[\"v1\"]}","delta":true}
{"type":"result","timestamp":"2026-03-30T10:00:02.000Z","status":"success"}
JSONL
MOCK
chmod +x "$mock_ok"

mock_slow="$(mktemp)"
cat > "$mock_slow" <<'MOCK'
#!/usr/bin/env bash
sleep 3
cat <<'JSON'
{"risks":["r1"],"strongest_counterargument":"c","recommendation":"do x","next_verification":["v1"]}
JSON
MOCK
chmod +x "$mock_slow"


mock_bad_type="$(mktemp)"
cat > "$mock_bad_type" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSONL'
{"type":"init","timestamp":"2026-03-30T10:00:00.000Z","session_id":"s-bad","model":"gemini-3-pro"}
{"type":"message","timestamp":"2026-03-30T10:00:01.000Z","role":"assistant","content":"{\"risks\":[{\"bad\":1}],\"strongest_counterargument\":\"c\",\"recommendation\":\"do x\",\"next_verification\":[\"v1\"]}","delta":true}
{"type":"result","timestamp":"2026-03-30T10:00:02.000Z","status":"success"}
JSONL
MOCK
chmod +x "$mock_bad_type"

mock_log_json="$(mktemp)"
cat > "$mock_log_json" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSONL'
{"type":"init","timestamp":"2026-03-30T10:00:00.000Z","session_id":"s-wrap","model":"gemini-3-pro"}
{"type":"message","timestamp":"2026-03-30T10:00:01.000Z","role":"assistant","content":"Note: use this object -> {\"risks\":[\"r1\"],\"strongest_counterargument\":\"c\",\"recommendation\":\"do x\",\"next_verification\":[\"v1\"]} <- end","delta":true}
{"type":"result","timestamp":"2026-03-30T10:00:02.000Z","status":"success"}
JSONL
MOCK
chmod +x "$mock_log_json"

mock_stream="$(mktemp)"
cat > "$mock_stream" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSONL'
{"type":"init","timestamp":"2026-03-29T10:00:00.000Z","session_id":"s1","model":"gemini-3-pro"}
{"type":"message","timestamp":"2026-03-29T10:00:01.000Z","role":"assistant","content":"{\"risks\":[\"r-stream\"],","delta":true}
{"type":"message","timestamp":"2026-03-29T10:00:02.000Z","role":"assistant","content":"\"strongest_counterargument\":\"c-stream\",\"recommendation\":\"from stream\",\"next_verification\":[\"v-stream\"]}","delta":true}
{"type":"result","timestamp":"2026-03-29T10:00:03.000Z","status":"success","stats":{"total_tokens":10,"input_tokens":6,"output_tokens":4,"cached":0,"input":6,"duration_ms":1200,"tool_calls":0,"models":{"gemini-3-pro":{"total_tokens":10,"input_tokens":6,"output_tokens":4,"cached":0,"input":6}}}}
JSONL
MOCK
chmod +x "$mock_stream"

mock_check_args="$(mktemp)"
cat > "$mock_check_args" <<'MOCK'
#!/usr/bin/env bash
if [[ " $* " != *" --output-format stream-json "* ]]; then
  echo "missing stream-json output format" >&2
  exit 3
fi
seen_prompt_flag=0
expect_prompt_value=0
for arg in "$@"; do
  if (( expect_prompt_value )); then
    if [[ -n "$arg" ]]; then
      echo "expected empty prompt arg when stdin carries the payload" >&2
      exit 4
    fi
    seen_prompt_flag=1
    expect_prompt_value=0
    continue
  fi
  if [[ "$arg" == "-p" || "$arg" == "--prompt" ]]; then
    expect_prompt_value=1
    continue
  fi
  if [[ "$arg" == *"=== BEGIN_CONTEXT ==="* || "$arg" == *"Primary question: q"* || "$arg" == *"ctx"* ]]; then
    echo "prompt payload should not be passed via argv" >&2
    exit 5
  fi
done
if (( expect_prompt_value || !seen_prompt_flag )); then
  echo "missing -p with empty prompt value" >&2
  exit 4
fi
stdin_payload="$(cat)"
if [[ "$stdin_payload" != *"Task type: review-commit"* || \
  "$stdin_payload" != *"Primary question: q"* || \
  "$stdin_payload" != *$'=== BEGIN_CONTEXT ===\nctx\n=== END_CONTEXT ==='* ]]; then
  echo "prompt payload missing from stdin" >&2
  exit 6
fi
cat <<'JSONL'
{"type":"init","timestamp":"2026-03-30T10:00:00.000Z","session_id":"s-args","model":"gemini-3-pro"}
{"type":"message","timestamp":"2026-03-30T10:00:01.000Z","role":"assistant","content":"{\"risks\":[\"r1\"],\"strongest_counterargument\":\"c\",\"recommendation\":\"do x\",\"next_verification\":[\"v1\"]}","delta":true}
{"type":"result","timestamp":"2026-03-30T10:00:02.000Z","status":"success"}
JSONL
MOCK
chmod +x "$mock_check_args"

mock_raw_only="$(mktemp)"
cat > "$mock_raw_only" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"risks":["r-raw"],"strongest_counterargument":"c-raw","recommendation":"from-raw-only","next_verification":["v-raw"]}
JSON
MOCK
chmod +x "$mock_raw_only"

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

# Test 7: sandbox env is detected and hard-fails with escalation hint
if CODEX_SANDBOX_NETWORK_DISABLED=1 \
  GEMINI_SECOND_OPINION_CMD="$mock_ok" \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') >/tmp/so_t7_out.txt 2>/tmp/so_t7_err.txt; then
  ng "sandbox detection should fail fast"
else
  rc=$?
  if [[ "$rc" == "77" ]] && grep -q 'sandbox_permissions="require_escalated"' /tmp/so_t7_err.txt; then
    ok "sandbox detection fails with escalation hint"
  else
    ng "sandbox detection code/message mismatch"
  fi
fi

# Test 8: deep type validation for risks[]
if GEMINI_SECOND_OPINION_CMD="$mock_bad_type" \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') > /tmp/so_t8_out.json 2>/tmp/so_t8_err.txt; then
  if jq -e '.status=="fallback" and .reason=="invalid-json"' /tmp/so_t8_out.json >/dev/null; then
    ok "deep type validation rejects non-string risks entries"
  else
    ng "deep type validation payload mismatch"
  fi
else
  ng "invalid-json in fail-open should still return zero"
fi

# Test 9: stream assistant text may include wrapper text; candidate extraction still recovers JSON
if GEMINI_SECOND_OPINION_CMD="$mock_log_json" \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') > /tmp/so_t9_out.json 2>/tmp/so_t9_err.txt; then
  if jq -e '.status=="ok" and .opinion.recommendation=="do x"' /tmp/so_t9_out.json >/dev/null; then
    ok "stream text candidate extraction recovers wrapped JSON"
  else
    ng "stream text candidate extraction failed"
  fi
else
  ng "wrapped stream text should still parse"
fi

# Test 10: stream-json event output is reconstructed correctly
if GEMINI_SECOND_OPINION_CMD="$mock_stream" \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') > /tmp/so_t10_out.json 2>/tmp/so_t10_err.txt; then
  if jq -e '.status=="ok" and .opinion.recommendation=="from stream" and .opinion.risks[0]=="r-stream"' /tmp/so_t10_out.json >/dev/null && \
    grep -q '"type":"message"' /tmp/so_t10_err.txt; then
    ok "stream-json parsing reconstructs assistant output and mirrors events"
  else
    ng "stream-json reconstruction or stderr mirroring mismatch"
  fi
else
  ng "stream-json output should parse successfully"
fi

# Test 11: command stays headless and sends prompt via stdin
if GEMINI_SECOND_OPINION_CMD="$mock_check_args" \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') > /tmp/so_t11_out.json 2>/tmp/so_t11_err.txt; then
  if jq -e '.status=="ok" and .opinion.recommendation=="do x"' /tmp/so_t11_out.json >/dev/null; then
    ok "command uses stdin prompt path in headless mode"
  else
    ng "stdin prompt path payload mismatch"
  fi
else
  ng "stdin prompt path should pass"
fi

# Test 12: raw-only output is rejected (no raw fallback path)
if GEMINI_SECOND_OPINION_CMD="$mock_raw_only" \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') > /tmp/so_t12_out.json 2>/tmp/so_t12_err.txt; then
  if jq -e '.status=="fallback" and .reason=="invalid-json"' /tmp/so_t12_out.json >/dev/null; then
    ok "raw-only output is rejected when stream events are missing"
  else
    ng "raw-only rejection payload mismatch"
  fi
else
  ng "raw-only invalid-json in fail-open should still return zero"
fi

# Test 13: timeout cleanup kills process group children
child_pid_file="$(mktemp)"
if GSO_CHILD_PID_FILE="$child_pid_file" \
  GEMINI_SECOND_OPINION_CMD="$mock_tree" \
  GEMINI_SECOND_OPINION_TIMEOUT_SEC=2 \
  "$SCRIPT" review-commit "q" < <(printf 'ctx') > /tmp/so_t13_out.json 2>/tmp/so_t13_err.txt; then
  if ! jq -e '.status=="fallback" and .reason=="gemini-timeout"' /tmp/so_t13_out.json >/dev/null; then
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

# Test 14: docs reflect single-path workflow
if grep -q "^## Workflow$" "$SKILL_FILE" && \
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

# Test 15: removed fallback async script
if [[ ! -e "$SCRIPT_DIR/parallel_review.sh" ]]; then
  ok "parallel_review.sh removed"
else
  ng "parallel_review.sh should be removed"
fi

# Test 16: subagent wrapper removed
if [[ ! -e "$SCRIPT_DIR/subagent_second_opinion.sh" ]]; then
  ok "subagent_second_opinion.sh removed"
else
  ng "subagent_second_opinion.sh should be removed"
fi

rm -f "$mock_ok" "$mock_slow" "$mock_bad_type" "$mock_log_json" "$mock_stream" "$mock_check_args" "$mock_raw_only" "$mock_tree" "$child_pid_file"

if [[ "$fail" == "0" ]]; then
  echo "All tests passed: $pass"
  exit 0
fi

echo "Tests failed: $fail (passed: $pass)"
exit 1
