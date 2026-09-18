#!/usr/bin/env bash
# End-to-end check that Hermes really fails over to its fallback model (gemma).
#
# Safe by design: it runs ONE throwaway one-shot Hermes process whose primary
# model is deliberately a name that doesn't exist. Hermes classifies that as
# `model_not_found` (404, or OpenRouter's 400 "is not a valid model") and fails
# over immediately, without retries — agent/error_classifier.py. The live
# gateway, config.yaml and every other session are untouched.
#
# Pass needs three independent signals:
#   1. Hermes logged "Fallback activated: ... -> <fallback model>" (agent.log)
#   2. gemma's own server saw a request (its /slots task counter changed)
#   3. the one-shot run completed without failure (usage report)
# The usage report's "model" is shown but not required — the source doesn't
# make clear whether it records the requested or the answering model.
#
#   tests/hermes_failover.sh
#   FAILOVER_TIMEOUT=1800 tests/hermes_failover.sh   # default 1200 s
#
# Expect it to be slow: gemma processes Hermes' full system prompt on CPU
# (thinking is off server-side, so replies themselves are quick). The timing
# is part of the result — it's how long a real failover turn would take.
set -uo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES=("${HERMES_HOME}/hermes-agent/venv/bin/python" -m hermes_cli.main)
AGENT_LOG="${HERMES_HOME}/logs/agent.log"
TIMEOUT="${FAILOVER_TIMEOUT:-1200}"
BOGUS_MODEL="inkys-gym/does-not-exist-failover-test"
PROMPT="This is an automated failover test. Reply with exactly: FAILOVER-OK"

fail() { echo "FAIL: $*"; exit 1; }

# --- Preflight: what is the fallback, and is it up? --------------------
fb_model="$(awk '/^fallback_model:/{f=1;next} f&&/^[^ ]/{exit} f&&/^  model:/{print $2}' "${HERMES_HOME}/config.yaml")"
fb_url="$(awk '/^fallback_model:/{f=1;next} f&&/^[^ ]/{exit} f&&/^  base_url:/{print $2}' "${HERMES_HOME}/config.yaml")"
[[ -n "${fb_model}" && -n "${fb_url}" ]] || fail "no fallback_model block in config.yaml"
server="${fb_url%/v1}"
echo "fallback: ${fb_model} at ${fb_url}"
curl -sf -m 5 "${server}/health" >/dev/null || fail "fallback server ${server} is not healthy"

slots_url="${server}/slots?model=$(jq -rn --arg m "${fb_model}" '$m | @uri')"
slot_marker() { curl -s -m 30 "${slots_url}" | jq -c '[.[]? | .id_task] | max' 2>/dev/null || echo null; }

# --- Run the forced failover -------------------------------------------
before_marker="$(slot_marker)"
log_lines_before="$(wc -l < "${AGENT_LOG}" 2>/dev/null || echo 0)"
usage_file="$(mktemp)"
out_file="$(mktemp)"
trap 'rm -f "${usage_file}" "${out_file}"' EXIT

echo "running one-shot Hermes with primary model '${BOGUS_MODEL}' (timeout ${TIMEOUT}s)..."
start=$(date +%s)
( cd "${HOME}" && timeout "${TIMEOUT}" "${HERMES[@]}" -z "${PROMPT}" \
    -m "${BOGUS_MODEL}" --provider openrouter --usage-file "${usage_file}" ) > "${out_file}" 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
after_marker="$(slot_marker)"

# --- Evidence ------------------------------------------------------------
new_log="$(tail -n +"$((log_lines_before + 1))" "${AGENT_LOG}" 2>/dev/null)"
activation="$(echo "${new_log}" | grep -F "Fallback activated" | tail -1)"
usage_model="$(jq -r '.model // empty' "${usage_file}" 2>/dev/null)"
usage_ok="$(jq -r 'if .completed == true and .failed == false then "yes" else "no" end' "${usage_file}" 2>/dev/null)"
reply="$(tail -c 400 "${out_file}")"

echo
echo "exit code:       ${rc}$([[ ${rc} == 124 ]] && echo ' (timed out)')"
echo "elapsed:         ${elapsed}s"
echo "reply:           ${reply:-<none>}"
echo "log:             ${activation:-<no 'Fallback activated' line>}"
echo "usage model:     ${usage_model:-<none>} (informational)"
echo "run completed:   ${usage_ok:-unknown}"
echo "gemma /slots:    task ${before_marker} -> ${after_marker}"

pass=1
[[ "${activation}" == *"${fb_model}"* ]] || { echo "  ✗ Hermes did not log a fallback to ${fb_model}"; pass=0; }
[[ "${after_marker}" != "${before_marker}" && "${after_marker}" != "null" ]] || { echo "  ✗ gemma's server saw no new request"; pass=0; }
[[ "${usage_ok}" == "yes" ]] || { echo "  ✗ the run didn't complete cleanly"; pass=0; }
[[ "${reply}" == *"FAILOVER-OK"* ]] || echo "  ⚠ reply didn't contain FAILOVER-OK (informational — the model may paraphrase)"

if [[ ${pass} == 1 ]]; then
    echo "PASS: Hermes failed over to ${fb_model} in ${elapsed}s"
else
    echo "FAIL — last Hermes log lines from this run:"
    echo "${new_log}" | grep -iE "fallback|error|warn" | tail -8
    exit 1
fi
