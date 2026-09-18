#!/usr/bin/env bash
# Plain chat with Inky (or any candidate), no persona.
#   exercise/chat.sh                 # interactive, keeps history for the session
#   exercise/chat.sh "one-shot prompt"
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/backend.sh"

BASE_URL="http://${INKY_HOST:-127.0.0.1}:${INKY_PORT:-45072}"
BACKEND="${INKY_BACKEND:-openai}"
MODEL_NAME="${INKY_MODEL_NAME:-Inky}"
# Thinking off by default: small reasoning models can spend the whole token
# budget on <think> output and never answer. INKY_THINKING=1 to watch it.
export LLM_MAX_TOKENS="${INKY_MAX_TOKENS:-512}" LLM_THINKING="${INKY_THINKING:-0}"

history="[]"
turn() {
    local response reply
    history="$(echo "${history}" | jq --arg c "$1" '. + [{role: "user", content: $c}]')"
    response="$(llm_chat "${BACKEND}" "${BASE_URL}" "${MODEL_NAME}" "${history}")"
    llm_display inky "${BACKEND}" "${response}"
    reply="$(llm_content "$(llm_message "${BACKEND}" "${response}")")"
    [[ -n "${reply}" ]] && history="$(echo "${history}" | jq --arg c "${reply}" '. + [{role: "assistant", content: $c}]')"
    return 0
}

if [[ $# -gt 0 ]]; then
    turn "$*"
    exit 0
fi

echo "Chatting with ${MODEL_NAME} at ${BASE_URL} (type 'exit' or Ctrl-D to quit)"
while read -r -p "you> " line; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" == "exit" || "${line}" == "quit" ]] && break
    turn "${line}"
done
