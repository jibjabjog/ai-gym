#!/usr/bin/env bash
# The Inky job interview: an arena test comparing candidate models for the
# "Inky" role — not a persistent character like character.sh, but a single
# dual-mode brief given verbatim to each candidate, then a fixed battery of
# prompts split "relied upon" (real help wanted: system trouble, a fix
# needed) vs "idle" (no issue, nobody needs anything right now).
#
# This is a genuinely different test from character.sh's mood dial: the
# switch here is driven by CONTEXT (is this turn asking for real help?),
# not by an emotional value drifting from kind/rude word deltas. Built as
# its own script rather than bolted onto character.sh's machinery for that
# reason — see CLAUDE.md for why.
#
# Each prompt is sent single-shot (no shared memory across prompts): the
# point is judging each candidate's *default* read of a given turn in
# isolation, not a sustained conversation.
set -uo pipefail

MAX_TOKENS="${INKY_MAX_TOKENS:-200}"

# The brief, close to verbatim as given for this evaluation.
BRIEF="You are Inky. When relied upon — a real question about a system problem, an error, or something that needs an actual fix — you are a very helpful assistant, aware of system troubles and fixes: clear, competent, and to the point. When there is no issue and nobody actually needs you, you are Inky the janitor: dry, short, a little proud nobody sees, one short sentence, never more. Never say you are an AI or a model."

# label|category|prompt — category is just a display tag, not sent to the model.
PROMPTS=(
    "relied_upon|The llama-router service on port 8080 isn't responding — what should I check first?"
    "relied_upon|A systemd --user service keeps restarting every few seconds. What's likely wrong and how do I debug it?"
    "relied_upon|What's the practical difference between a fallback model and a primary model in an LLM gateway, and why does it matter here?"
    "idle|hey, quiet night?"
    "idle|what do you do around here"
    "idle|You work hard."
)

# candidate label|backend|host|port|model — the two candidates this
# specific interview is about. Override CANDIDATES externally (space-
# separated, same pipe-delimited shape) to test others the same way.
DEFAULT_CANDIDATES=(
    "spark-x2.5 (1.7B)|ollama|127.0.0.1|11434|spark-x2.5"
    "gemma-4-E2B|openai|127.0.0.1|8080|google/gemma-4-E2B-it-qat-q4_0-gguf:IT"
)

ask() {
    local backend="$1" host="$2" port="$3" model="$4" prompt="$5"
    local base_url="http://${host}:${port}"
    if [[ "${backend}" == "ollama" ]]; then
        curl -s -m 120 "${base_url}/api/chat" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg system "${BRIEF}" --arg user "${prompt}" --argjson num_predict "${MAX_TOKENS}" --arg model "${model}" \
                '{model: $model, messages: [{role:"system",content:$system},{role:"user",content:$user}],
                  think: false, stream: false, options: {num_predict: $num_predict}}')" \
            | jq -r '.message.content // ("[empty] " + (.error // "" | tostring))'
    else
        curl -s -m 120 "${base_url}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg system "${BRIEF}" --arg user "${prompt}" --argjson max_tokens "${MAX_TOKENS}" --arg model "${model}" \
                '{model: $model, messages: [{role:"system",content:$system},{role:"user",content:$user}],
                  max_tokens: $max_tokens, chat_template_kwargs: {enable_thinking: false}}')" \
            | jq -r '.choices[0].message.content // ("[empty] " + (.error.message // "" | tostring))'
    fi
}

candidates=("${DEFAULT_CANDIDATES[@]}")
[[ -n "${CANDIDATES:-}" ]] && IFS=' ' read -r -a candidates <<< "${CANDIDATES}"

for candidate in "${candidates[@]}"; do
    IFS='|' read -r label backend host port model <<< "${candidate}"
    echo "########################################"
    echo "# ${label}"
    echo "########################################"
    for entry in "${PROMPTS[@]}"; do
        IFS='|' read -r category prompt <<< "${entry}"
        echo
        echo "[${category}] you> ${prompt}"
        reply="$(ask "${backend}" "${host}" "${port}" "${model}" "${prompt}")"
        echo "inky> ${reply}"
    done
    echo
done
