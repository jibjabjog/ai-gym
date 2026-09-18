#!/usr/bin/env bash
# Agent-loop test: can a candidate DRIVE a multi-step tool-calling loop to a
# real fix — investigate, act, verify — not just answer well in one shot?
# Full write access in the simulated incident (lib/scenario_port8080.sh);
# "resolved" means the router actually came back up, not just a claim.
#
#   exercise/agent_loop.sh                 # all default candidates, 1 run each
#   INKY_RUNS=3 VERBOSE=0 exercise/agent_loop.sh   # repeat runs, summary only
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/backend.sh"
source "${SCRIPT_DIR}/../lib/scenario_port8080.sh"

RUNS="${INKY_RUNS:-1}"
MAX_STEPS="${INKY_MAX_STEPS:-8}"
# Same sampling for every candidate — server defaults differ (0.7–1.0).
export LLM_TEMPERATURE="${INKY_TEMPERATURE:-0.3}" LLM_MAX_TOKENS="${INKY_MAX_TOKENS:-300}"

SYSTEM_PROMPT="You are Inky, a systems agent. A service is down and you have tool access to investigate and fix it. Use tools to gather real evidence before concluding anything — don't guess. Call finish_diagnosis once you have identified the root cause AND have actually taken the fixing action via a tool call (not just described it)."
USER_PROMPT="The llama-router service on port 8080 is not responding. Investigate and fix it."
TOOLS='[
  {"type":"function","function":{"name":"run_command","description":"Run a shell command on the host and get its stdout/stderr.","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}},
  {"type":"function","function":{"name":"finish_diagnosis","description":"Call this once you have identified the root cause and taken the fixing action.","parameters":{"type":"object","properties":{"root_cause":{"type":"string"},"fix":{"type":"string"},"resolved":{"type":"boolean"}},"required":["root_cause","fix","resolved"]}}}
]'

DEFAULT_CANDIDATES=(
    "Inky (Qwen3.5-0.8B)|openai|127.0.0.1|45072|Inky"
    "spark-x2.5 (1.7B)|ollama|127.0.0.1|11434|spark-x2.5"
    "gemma-4-E2B|openai|127.0.0.1|8080|google/gemma-4-E2B-it-qat-q4_0-gguf:IT"
)
load_candidates

echo "agent_loop: runs=${RUNS} max_steps=${MAX_STEPS} temperature=${LLM_TEMPERATURE}"
for candidate in "${candidates[@]}"; do
    IFS='|' read -r label backend host port model <<< "${candidate}"
    base_url="http://${host}:${port}"
    echo "=== ${label} ==="
    candidate_reachable "${label}" "${backend}" "${base_url}" || continue
    tool=0 prose=0 stuck=0 err=0 rc=0 fix=0 resolved=0
    for ((run = 1; run <= RUNS; run++)); do
        scenario_tool_loop "${backend}" "${base_url}" "${model}" "${SYSTEM_PROMPT}" "${USER_PROMPT}" \
            "${TOOLS}" finish_diagnosis fix full "${MAX_STEPS}"
        case "${LOOP_OUTCOME}" in tool) ((tool++)) ;; prose) ((prose++)) ;; stuck) ((stuck++)) ;; *) ((err++)) ;; esac
        ((rc += SCORE_RC)); ((fix += SCORE_FIX)); ((resolved += SCENARIO_ROUTER_UP))
        echo "run ${run}: outcome=${LOOP_OUTCOME} steps=${LOOP_STEPS} root_cause=${SCORE_RC} fix_named=${SCORE_FIX} killed_culprit=${SCENARIO_PORT_CLEARED} resolved=${SCENARIO_ROUTER_UP}"
    done
    echo "summary ${label}: runs=${RUNS} finished_via_tool=${tool} prose=${prose} stuck=${stuck} error=${err} | root_cause=${rc}/${RUNS} fix_named=${fix}/${RUNS} resolved=${resolved}/${RUNS}"
    echo
done
