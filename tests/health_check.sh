#!/usr/bin/env bash
# Verify Inky (the local llama.cpp failover model) is up and responding.
#
# Since the 2026-09-24 retirement, "Inky" is gemma-4-E2B served by the
# llama-router.service systemd --user unit on 127.0.0.1:8080 (the sole local
# failover; also Hermes' live fallback). The old llama-qwen35-tiny.service on
# :45072 is gone. This check is read-only (GET /health, GET /v1/models,
# systemctl is-active), so it is safe to run against the live fallback.
# Override INKY_PORT / INKY_UNIT to point at any other candidate.
set -uo pipefail

INKY_HOST="${INKY_HOST:-127.0.0.1}"
INKY_PORT="${INKY_PORT:-8080}"
BASE_URL="http://${INKY_HOST}:${INKY_PORT}"
UNIT="${INKY_UNIT:-llama-router.service}"

fail=0

echo "== systemd unit: ${UNIT} =="
if systemctl --user is-active --quiet "${UNIT}"; then
    echo "OK: ${UNIT} is active"
else
    echo "FAIL: ${UNIT} is not active (state: $(systemctl --user is-active "${UNIT}" 2>&1))"
    fail=1
fi

echo "== ${BASE_URL}/health =="
health="$(curl -s -m 5 "${BASE_URL}/health")"
if [[ "$(echo "${health}" | jq -r '.status' 2>/dev/null)" == "ok" ]]; then
    echo "OK: ${health}"
else
    echo "FAIL: unexpected response: ${health:-<no response>}"
    fail=1
fi

echo "== ${BASE_URL}/v1/models =="
models="$(curl -s -m 5 "${BASE_URL}/v1/models")"
model_id="$(echo "${models}" | jq -r '.data[0].id' 2>/dev/null)"
if [[ -n "${model_id}" && "${model_id}" != "null" ]]; then
    echo "OK: model available: ${model_id}"
else
    echo "FAIL: no model reported: ${models:-<no response>}"
    fail=1
fi

if [[ "${fail}" -eq 0 ]]; then
    echo "== Inky is healthy =="
else
    echo "== Inky health check FAILED =="
fi

exit "${fail}"
