#!/usr/bin/env bash
# Start a chat with Inky.
#
# Interactive by default (multi-turn, keeps history for the session).
# Pass a prompt as an argument for a single-shot, non-interactive exchange.
set -uo pipefail

INKY_HOST="${INKY_HOST:-127.0.0.1}"
INKY_PORT="${INKY_PORT:-45072}"
BASE_URL="http://${INKY_HOST}:${INKY_PORT}"
MAX_TOKENS="${INKY_MAX_TOKENS:-512}"
# Inky is a small reasoning model: left to think, it can burn the whole
# token budget on visible <think> output and never reach an answer.
# Off by default for a snappy chat; set INKY_THINKING=1 to see its reasoning.
THINKING="${INKY_THINKING:-0}"
# "openai" talks to a llama.cpp-style /v1/chat/completions server (Inky's
# native API). "ollama" talks to ollama's own /api/chat instead — needed
# because ollama's OpenAI-compat endpoint ignores the thinking toggle
# entirely; only its native API respects `think`. See character.sh for the
# same split, and CLAUDE.md for why (spark-x2.5 evaluation, 2026-09-16).
BACKEND="${INKY_BACKEND:-openai}"
MODEL_NAME="${INKY_MODEL_NAME:-Inky}"

send() {
    local history="$1"
    local enable_thinking="false"
    [[ "${THINKING}" == "1" ]] && enable_thinking="true"

    if [[ "${BACKEND}" == "ollama" ]]; then
        curl -s -m 120 "${BASE_URL}/api/chat" \
            -H "Content-Type: application/json" \
            -d "$(jq -n \
                --argjson messages "${history}" \
                --argjson num_predict "${MAX_TOKENS}" \
                --argjson think "${enable_thinking}" \
                --arg model "${MODEL_NAME}" \
                '{model: $model, messages: $messages, think: $think, stream: false,
                  options: {num_predict: $num_predict}}')"
    else
        curl -s -m 120 "${BASE_URL}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$(jq -n \
                --argjson messages "${history}" \
                --argjson max_tokens "${MAX_TOKENS}" \
                --argjson enable_thinking "${enable_thinking}" \
                --arg model "${MODEL_NAME}" \
                '{model: $model, messages: $messages, max_tokens: $max_tokens,
                  chat_template_kwargs: {enable_thinking: $enable_thinking}}')"
    fi
}

reply_content() {
    if [[ "${BACKEND}" == "ollama" ]]; then
        echo "$1" | jq -r '.message.content // empty'
    else
        echo "$1" | jq -r '.choices[0].message.content // empty'
    fi
}

# Prints the assistant's reply, falling back to reasoning if the visible
# content came back empty (e.g. generation got cut off mid-thought).
print_reply() {
    local response="$1" content reasoning
    content="$(reply_content "${response}")"
    if [[ -n "${content}" ]]; then
        echo "inky> ${content}"
    else
        if [[ "${BACKEND}" == "ollama" ]]; then
            reasoning="$(echo "${response}" | jq -r '.message.thinking // empty')"
        else
            reasoning="$(echo "${response}" | jq -r '.choices[0].message.reasoning_content // empty')"
        fi
        if [[ -n "${reasoning}" ]]; then
            echo "inky> (no reply yet, still reasoning) ${reasoning}"
        else
            echo "inky> [empty response] $(echo "${response}" | jq -c '.error // .')"
        fi
    fi
}

if [[ $# -gt 0 ]]; then
    # Single-shot mode.
    history="$(jq -n --arg content "$*" '[{role: "user", content: $content}]')"
    response="$(send "${history}")"
    print_reply "${response}"
    exit 0
fi

# Interactive mode.
echo "Chatting with Inky at ${BASE_URL} (type 'exit' or Ctrl-D to quit)"
history="[]"
while true; do
    read -r -p "you> " line || { echo; break; }
    [[ -z "${line}" ]] && continue
    [[ "${line}" == "exit" || "${line}" == "quit" ]] && break

    history="$(echo "${history}" | jq --arg content "${line}" '. + [{role: "user", content: $content}]')"
    response="$(send "${history}")"
    print_reply "${response}"

    reply="$(reply_content "${response}")"
    if [[ -n "${reply}" ]]; then
        history="$(echo "${history}" | jq --arg content "${reply}" '. + [{role: "assistant", content: $content}]')"
    fi
done
