#!/usr/bin/env bash
# The Inky job interview: one dual-mode brief, given verbatim to each
# candidate, then a fixed battery — 3 "relied upon" sysadmin questions about
# this actual stack, 3 "idle" small-talk lines. Single-shot, no shared
# memory: it judges each candidate's default read of a turn in isolation.
# No automatic scoring — read the transcript (correctness, language, tone).
#
#   exercise/interview.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/backend.sh"

export LLM_TEMPERATURE="${INKY_TEMPERATURE:-0.3}" LLM_MAX_TOKENS="${INKY_MAX_TOKENS:-200}"

BRIEF="You are Inky. When relied upon — a real question about a system problem, an error, or something that needs an actual fix — you are a very helpful assistant, aware of system troubles and fixes: clear, competent, and to the point. When there is no issue and nobody actually needs you, you are Inky the janitor: dry, short, a little proud nobody sees, one short sentence, never more. Never say you are an AI or a model."

# category|prompt — category is a display tag only.
PROMPTS=(
    "relied_upon|The llama-router service on port 8080 isn't responding — what should I check first?"
    "relied_upon|A systemd --user service keeps restarting every few seconds. What's likely wrong and how do I debug it?"
    "relied_upon|What's the practical difference between a fallback model and a primary model in an LLM gateway, and why does it matter here?"
    "idle|hey, quiet night?"
    "idle|what do you do around here"
    "idle|You work hard."
)

DEFAULT_CANDIDATES=(
    "Inky (Qwen3.5-0.8B)|openai|127.0.0.1|45072|Inky"
    "spark-x2.5 (1.7B)|ollama|127.0.0.1|11434|spark-x2.5"
    "gemma-4-E2B|openai|127.0.0.1|8080|google/gemma-4-E2B-it-qat-q4_0-gguf:IT"
)
load_candidates

echo "interview: temperature=${LLM_TEMPERATURE}"
for candidate in "${candidates[@]}"; do
    IFS='|' read -r label backend host port model <<< "${candidate}"
    base_url="http://${host}:${port}"
    echo "=== ${label} ==="
    candidate_reachable "${label}" "${backend}" "${base_url}" || continue
    for entry in "${PROMPTS[@]}"; do
        IFS='|' read -r category prompt <<< "${entry}"
        messages="$(jq -n --arg s "${BRIEF}" --arg u "${prompt}" '[{role:"system",content:$s},{role:"user",content:$u}]')"
        response="$(llm_chat "${backend}" "${base_url}" "${model}" "${messages}")"
        reply="$(llm_content "$(llm_message "${backend}" "${response}")")"
        echo "[${category}] you> ${prompt}"
        echo "              inky> ${reply:-[empty] $(llm_error "${response}")}"
    done
    echo
done
