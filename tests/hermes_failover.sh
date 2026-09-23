#!/usr/bin/env bash
# Does Hermes really fail over to its fallback model (gemma)? Runs ONE throwaway
# one-shot Hermes whose primary model is a deliberately nonexistent name; Hermes
# classifies that as model_not_found and fails over at once, with no retries
# (agent/error_classifier.py). The live gateway and config.yaml are untouched.
#
# The proof is Hermes' OWN socket to the fallback server: the one-shot process
# (matched by pid) opens a connection to the fallback port. A one-shot run does
# not write "Fallback activated" to agent.log, so that line is not required.
#
#   tests/hermes_failover.sh            # QUICK (default): PASS once routed, ~10-30 s
#   FULL=1 tests/hermes_failover.sh     # also wait for gemma's actual reply
#   FORCE=1 tests/hermes_failover.sh    # run even if gemma is busy
#
# Why QUICK is the default: on this CPU box gemma reads prompts at only ~20 tok/s
# and Hermes' fixed prompt (system + 23 tool schemas) is ~20k tokens, so a COLD
# first turn can take 15-20 minutes. Once digested, the prompt cache makes repeat
# turns near-instant. QUICK proves the routing without waiting for that. Killing
# the one-shot does NOT cancel gemma's work — it keeps digesting the prompt, which
# is harmless (it warms the cache; fallback_guard.sh treats a working model as
# busy, never down).
set -uo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES=("${HERMES_HOME}/hermes-agent/venv/bin/python" -m hermes_cli.main)
AGENT_LOG="${HERMES_HOME}/logs/agent.log"
FULL="${FULL:-0}"
TIMEOUT="${FAILOVER_TIMEOUT:-$([[ ${FULL} == 1 ]] && echo 2400 || echo 120)}"
BOGUS_MODEL="inkys-gym/does-not-exist-failover-test"
PROMPT="This is an automated failover test. Reply with exactly: FAILOVER-OK"

fail() { echo "FAIL: $*"; exit 1; }

# --- Preflight ---------------------------------------------------------
fb_model="$(awk '/^fallback_model:/{f=1;next} f&&/^[^ ]/{exit} f&&/^  model:/{print $2}' "${HERMES_HOME}/config.yaml")"
fb_url="$(awk '/^fallback_model:/{f=1;next} f&&/^[^ ]/{exit} f&&/^  base_url:/{print $2}' "${HERMES_HOME}/config.yaml")"
[[ -n "${fb_model}" && -n "${fb_url}" ]] || fail "no fallback_model block in config.yaml"
server="${fb_url%/v1}"
port="${server##*:}"
echo "fallback: ${fb_model} at ${fb_url}"
curl -sf -m 5 "${server}/health" >/dev/null || fail "fallback server ${server} is not healthy"

# The model process, found by the alias the router gives it.
model_pid="$(pgrep -f -- "--alias ${fb_model}" | head -1)"
cpu_pct() {   # % of one core the model used over 2 s
    local t1 t2 hz
    [[ -n "${model_pid}" ]] || { echo 0; return; }
    hz="$(getconf CLK_TCK)"
    t1="$(awk '{print $14+$15}' "/proc/${model_pid}/stat" 2>/dev/null || echo 0)"; sleep 2
    t2="$(awk '{print $14+$15}' "/proc/${model_pid}/stat" 2>/dev/null || echo 0)"
    echo $(( (t2 - t1) * 100 / (2 * hz) ))
}
busy_pct="$(cpu_pct)"
if (( busy_pct >= 100 )) && [[ "${FORCE:-0}" != 1 ]]; then
    fail "gemma is busy (${busy_pct}% CPU) — probably still digesting an earlier prompt, and this run would queue behind it. Wait for it to go idle, or FORCE=1."
fi
echo "gemma idle: ${busy_pct}% CPU. mode: $([[ ${FULL} == 1 ]] && echo FULL || echo QUICK), timeout ${TIMEOUT}s"

# --- Run the forced failover in the background so we can watch its sockets
usage_file="$(mktemp)"; out_file="$(mktemp)"
trap 'kill "${hpid:-}" 2>/dev/null; rm -f "${usage_file}" "${out_file}"' EXIT
log_lines_before="$(wc -l < "${AGENT_LOG}" 2>/dev/null || echo 0)"

echo "starting one-shot Hermes with primary model '${BOGUS_MODEL}'..."
start=$(date +%s)
( cd "${HOME}" && exec "${HERMES[@]}" -z "${PROMPT}" -m "${BOGUS_MODEL}" --provider openrouter \
    --usage-file "${usage_file}" ) > "${out_file}" 2>&1 &
hpid=$!

routed=0; t_routed=""; last_note=0
while kill -0 "${hpid}" 2>/dev/null; do
    now=$(( $(date +%s) - start ))
    if (( routed == 0 )) && ss -Htnp state established "( dport = :${port} )" 2>/dev/null | grep -q "pid=${hpid},"; then
        routed=1; t_routed="${now}"
        echo "  -> Hermes opened a connection to ${server} after ${t_routed}s: FAILED OVER to the fallback"
        [[ "${FULL}" == 1 ]] || break
    fi
    (( now >= TIMEOUT )) && { echo "  timed out after ${now}s"; break; }
    if (( now - last_note >= 30 )); then last_note=${now}; echo "  ... ${now}s"; fi
    sleep 1
done

finished=0
if ! kill -0 "${hpid}" 2>/dev/null; then finished=1; wait "${hpid}" 2>/dev/null; rc=$?; else rc=""; fi
elapsed=$(( $(date +%s) - start ))
[[ "${finished}" == 1 ]] || { kill "${hpid}" 2>/dev/null; wait "${hpid}" 2>/dev/null; }

# --- Evidence ---------------------------------------------------------
reply="$(tail -c 300 "${out_file}")"
usage_ok="$(jq -r 'if .completed == true and .failed == false then "yes" else "no" end' "${usage_file}" 2>/dev/null)"
activation="$(tail -n +"$((log_lines_before + 1))" "${AGENT_LOG}" 2>/dev/null | grep -F "Fallback activated" | tail -1)"
echo
echo "routed to fallback: $([[ ${routed} == 1 ]] && echo "yes (${t_routed}s)" || echo NO)"
echo "elapsed:            ${elapsed}s"
if [[ "${FULL}" == 1 ]]; then
    echo "run completed:      ${usage_ok:-unknown}   exit code: ${rc:-killed}"
    echo "reply:              ${reply:-<none>}"
fi
[[ -n "${activation}" ]] && echo "log:                ${activation}"

if [[ "${routed}" != 1 ]]; then
    echo "FAIL: Hermes never connected to the fallback. Its output:"; echo "${reply:-<none>}"; exit 1
fi
if [[ "${FULL}" == 1 && "${usage_ok}" != "yes" ]]; then
    echo "FAIL: routed to the fallback but the run did not complete cleanly (timeout ${TIMEOUT}s?)"; exit 1
fi
if [[ "${FULL}" == 1 ]]; then
    [[ "${reply}" == *"FAILOVER-OK"* ]] || echo "  note: reply didn't contain FAILOVER-OK (the model may paraphrase)"
    echo "PASS: failed over to ${fb_model} and completed in ${elapsed}s"
else
    echo "PASS (quick): Hermes fails over to ${fb_model} in ${t_routed}s — completion not awaited"
    echo "  (gemma may keep digesting the prompt for a while; harmless. Use FULL=1 to wait for the reply.)"
fi
