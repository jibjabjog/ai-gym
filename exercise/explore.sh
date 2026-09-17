#!/usr/bin/env bash
# Explore Inky's capabilities and specification: model, context size,
# modalities, chat template features, default sampling, and slot usage.
set -uo pipefail

INKY_HOST="${INKY_HOST:-127.0.0.1}"
INKY_PORT="${INKY_PORT:-45072}"
BASE_URL="http://${INKY_HOST}:${INKY_PORT}"

props="$(curl -s -m 5 "${BASE_URL}/props")"
if [[ -z "${props}" ]]; then
    echo "FAIL: no response from ${BASE_URL}/props"
    exit 1
fi

echo "== Model =="
echo "${props}" | jq -r '
    "alias:        \(.model_alias)",
    "path:         \(.model_path)",
    "build:        \(.build_info)",
    "context size: \(.default_generation_settings.n_ctx) tokens",
    "total slots:  \(.total_slots)"'

echo
echo "== Modalities =="
echo "${props}" | jq -r '.modalities | to_entries[] | "\(.key): \(.value)"'

echo
echo "== Chat template capabilities =="
echo "${props}" | jq -r '.chat_template_caps | to_entries[] | "\(.key): \(.value)"'

echo
echo "== Default sampling params =="
echo "${props}" | jq -r '.default_generation_settings.params |
    "temperature:     \(.temperature)",
    "top_p:           \(.top_p)",
    "top_k:           \(.top_k)",
    "min_p:           \(.min_p)",
    "repeat_penalty:  \(.repeat_penalty)",
    "reasoning:       \(.reasoning_format)"'

echo
echo "== Live slot usage (/slots) =="
slots="$(curl -s -m 5 "${BASE_URL}/slots")"
if [[ -n "${slots}" && "${slots}" != "null" ]]; then
    echo "${slots}" | jq -r '.[] | "slot \(.id): processing=\(.is_processing) n_ctx=\(.n_ctx)"'
else
    echo "(not available: ${slots:-endpoint disabled})"
fi

echo
echo "== Available models (/v1/models) =="
curl -s -m 5 "${BASE_URL}/v1/models" | jq -r '.data[] | "\(.id) — n_ctx_train=\(.meta.n_ctx_train) n_params=\(.meta.n_params)"'
