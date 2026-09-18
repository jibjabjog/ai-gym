#!/usr/bin/env bash
# Quick single-shot throughput check for Inky via llama.cpp's native
# /completion endpoint (raw prompt, no chat template). For comparisons across
# candidates or backends use tests/bench.sh — one reading on this shared box
# was once off by 5x.
set -uo pipefail

INKY_HOST="${INKY_HOST:-127.0.0.1}"
INKY_PORT="${INKY_PORT:-45072}"
BASE_URL="http://${INKY_HOST}:${INKY_PORT}"

PROMPT="${1:-Write a short paragraph about gyms for AI agents.}"
N_PREDICT="${2:-128}"

echo "== Requesting ${N_PREDICT} tokens from Inky (${BASE_URL}) =="

response="$(curl -s -m 120 "${BASE_URL}/completion" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg prompt "${PROMPT}" --argjson n_predict "${N_PREDICT}" \
        '{prompt: $prompt, n_predict: $n_predict}')")"

if [[ -z "${response}" ]]; then
    echo "FAIL: no response from Inky"
    exit 1
fi

timings="$(echo "${response}" | jq '.timings' 2>/dev/null)"
if [[ -z "${timings}" || "${timings}" == "null" ]]; then
    echo "FAIL: no timings in response: ${response}"
    exit 1
fi

predicted_n="$(echo "${timings}" | jq -r '.predicted_n')"
predicted_per_second="$(echo "${timings}" | jq -r '.predicted_per_second')"
prompt_n="$(echo "${timings}" | jq -r '.prompt_n')"
prompt_per_second="$(echo "${timings}" | jq -r '.prompt_per_second')"

echo "prompt tokens:     ${prompt_n} (${prompt_per_second} tok/s)"
echo "generated tokens:  ${predicted_n} (${predicted_per_second} tok/s)"
