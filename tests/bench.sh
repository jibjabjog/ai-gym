#!/usr/bin/env bash
# Controlled throughput benchmark: identical prompt, temperature 0, thinking
# off, one warmup (absorbs cold load) then N measured runs per candidate,
# generation tok/s read from the server's own timing fields. This is the
# method behind the scorecard's throughput row — a single ad-hoc reading on
# this shared box was once off by 5x (see FINDINGS.md).
#
#   tests/bench.sh                              # default candidates
#   BENCH_RUNS=5 CANDIDATES="label|backend|host|port|model" tests/bench.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/backend.sh"

RUNS="${BENCH_RUNS:-3}"
export LLM_TEMPERATURE=0 LLM_MAX_TOKENS="${BENCH_MAX_TOKENS:-150}" LLM_TIMEOUT=600
PROMPT="Explain in a few sentences how a tokens-per-second benchmark for a language model works."

DEFAULT_CANDIDATES=(
    "Inky (Qwen3.5-0.8B)|openai|127.0.0.1|45072|Inky"
    "spark-x2.5 (1.7B)|ollama|127.0.0.1|11434|spark-x2.5"
    "gemma-4-E2B|openai|127.0.0.1|8080|google/gemma-4-E2B-it-qat-q4_0-gguf:IT"
)
load_candidates

# Prints "<generated_tokens> <tok_per_s>" for one request.
measure() {
    local backend="$1" base_url="$2" model="$3" messages response
    messages="$(jq -n --arg p "${PROMPT}" '[{role:"user",content:$p}]')"
    response="$(llm_chat "${backend}" "${base_url}" "${model}" "${messages}")"
    if [[ "${backend}" == "ollama" ]]; then
        echo "${response}" | jq -r '"\(.eval_count) \(.eval_count / (.eval_duration / 1e9))"'
    else
        echo "${response}" | jq -r '"\(.timings.predicted_n) \(.timings.predicted_per_second)"'
    fi
}

echo "bench: warmup + ${RUNS} runs, max_tokens=${LLM_MAX_TOKENS}, temperature=0"
for candidate in "${candidates[@]}"; do
    IFS='|' read -r label backend host port model <<< "${candidate}"
    base_url="http://${host}:${port}"
    candidate_reachable "${label}" "${backend}" "${base_url}" || continue
    measure "${backend}" "${base_url}" "${model}" >/dev/null
    rates=()
    for ((i = 1; i <= RUNS; i++)); do
        read -r n rate <<< "$(measure "${backend}" "${base_url}" "${model}")"
        rates+=("${rate}")
        printf '  %-22s run %d: %4s tokens  %6.1f tok/s\n' "${label}" "${i}" "${n}" "${rate}"
    done
    printf '%-24s avg %6.1f tok/s\n' "${label}" "$(printf '%s\n' "${rates[@]}" | awk '{s+=$1} END {print s/NR}')"
done
