# Shared backend plumbing, sourced by every script that talks to a model.
# Two API shapes: "openai" (llama.cpp /v1/chat/completions) and "ollama"
# (/api/chat — its OpenAI-compat endpoint ignores the thinking toggle).
#
# Optional sampling knobs, read at call time (unset = server default):
#   LLM_MAX_TOKENS  LLM_TEMPERATURE  LLM_REPEAT_PENALTY  LLM_THINKING=1

# Sampling params as a JSON object, keyed the way each backend expects.
_llm_sampling() {
    jq -n --arg b "$1" --arg mt "${LLM_MAX_TOKENS:-}" --arg t "${LLM_TEMPERATURE:-}" --arg rp "${LLM_REPEAT_PENALTY:-}" '
        {}
        + (if $mt != "" then {(if $b == "ollama" then "num_predict" else "max_tokens" end): ($mt | tonumber)} else {} end)
        + (if $t  != "" then {temperature: ($t | tonumber)} else {} end)
        + (if $rp != "" then {repeat_penalty: ($rp | tonumber)} else {} end)'
}

# llm_chat BACKEND BASE_URL MODEL MESSAGES_JSON [TOOLS_JSON] -> raw response
llm_chat() {
    local backend="$1" base_url="$2" model="$3" messages="$4" tools="${5:-null}"
    local think="false" sampling body
    [[ "${LLM_THINKING:-0}" == "1" ]] && think="true"
    sampling="$(_llm_sampling "${backend}")"
    if [[ "${backend}" == "ollama" ]]; then
        body="$(jq -n --arg model "${model}" --argjson messages "${messages}" --argjson tools "${tools}" \
            --argjson think "${think}" --argjson s "${sampling}" \
            '{model: $model, messages: $messages, think: $think, stream: false, options: $s}
             + (if $tools then {tools: $tools} else {} end)')"
        curl -s -m "${LLM_TIMEOUT:-180}" "${base_url}/api/chat" -H "Content-Type: application/json" -d "${body}"
    else
        body="$(jq -n --arg model "${model}" --argjson messages "${messages}" --argjson tools "${tools}" \
            --argjson think "${think}" --argjson s "${sampling}" \
            '{model: $model, messages: $messages, chat_template_kwargs: {enable_thinking: $think}} + $s
             + (if $tools then {tools: $tools} else {} end)')"
        curl -s -m "${LLM_TIMEOUT:-180}" "${base_url}/v1/chat/completions" -H "Content-Type: application/json" -d "${body}"
    fi
}

# The assistant message as returned (keep it verbatim for history round-trips).
llm_message() {
    local backend="$1" response="$2"
    if [[ "${backend}" == "ollama" ]]; then
        echo "${response}" | jq -c '.message // null' 2>/dev/null || echo null
    else
        echo "${response}" | jq -c '.choices[0].message // null' 2>/dev/null || echo null
    fi
}

llm_content()   { echo "$1" | jq -r '.content // empty' 2>/dev/null; }
llm_reasoning() { echo "$1" | jq -r '.reasoning_content // .thinking // empty' 2>/dev/null; }

# Normalized tool calls: [{id, name, args}] with args always an object —
# llama.cpp returns arguments as a JSON-encoded string, ollama as an object.
llm_tool_calls() {
    echo "$1" | jq -c '[(.tool_calls // [])[] | {
        id: (.id // ""),
        name: .function.name,
        args: (.function.arguments | if type == "string" then (try fromjson catch {}) else . end)
    }]' 2>/dev/null || echo "[]"
}

llm_error() { echo "$1" | jq -r '(.error.message // .error // empty) | tostring' 2>/dev/null; }

# 0 if the backend answers its health endpoint.
llm_healthy() {
    local backend="$1" base_url="$2"
    if [[ "${backend}" == "ollama" ]]; then
        curl -sf -m 5 "${base_url}/api/tags" >/dev/null
    else
        curl -sf -m 5 "${base_url}/health" >/dev/null
    fi
}

# Candidates are "label|backend|host|port|model" lines. Sets the global
# `candidates` array from DEFAULT_CANDIDATES, or from the CANDIDATES env var
# (newline-separated — labels may contain spaces).
load_candidates() {
    candidates=("${DEFAULT_CANDIDATES[@]}")
    [[ -n "${CANDIDATES:-}" ]] && mapfile -t candidates <<< "${CANDIDATES}"
    return 0
}

# Prints a skip line and returns 1 if the candidate's backend isn't up.
candidate_reachable() {
    local label="$1" backend="$2" base_url="$3"
    llm_healthy "${backend}" "${base_url}" && return 0
    local hint=""
    [[ "${base_url}" == *":8080" ]] && hint=" (llama-router.service is down — it's Hermes' live fallback, check it)"
    [[ "${backend}" == "ollama" ]] && hint=" (is ollama running?)"
    echo "SKIP ${label}: ${base_url} not reachable${hint}"
    return 1
}

# llm_display PREFIX BACKEND RESPONSE — print the reply; if the visible
# content is empty (small reasoning models can burn the whole token budget
# thinking), show the reasoning instead, else the backend error.
llm_display() {
    local prefix="$1" msg content reasoning
    msg="$(llm_message "$2" "$3")"
    content="$(llm_content "${msg}")"
    reasoning="$(llm_reasoning "${msg}")"
    if [[ -n "${content}" ]]; then
        echo "${prefix}> ${content}"
    elif [[ -n "${reasoning}" ]]; then
        echo "${prefix}> (no reply yet, still reasoning) ${reasoning}"
    else
        echo "${prefix}> [empty response] $(llm_error "$3")"
    fi
}
