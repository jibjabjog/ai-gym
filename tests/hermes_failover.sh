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
# Why QUICK is the default: on this CPU box gemma reads prompts at only ~11-40 tok/s
# (slows as context grows) and Hermes' fixed prompt (system + tool schemas) is ~19k
# tokens, so a COLD first turn can take ~30 min. Once digested, the prompt cache makes
# repeat turns near-instant (1-2s). QUICK proves the routing without waiting for that.
# Killing the one-shot does NOT cancel gemma's work — it keeps digesting the prompt,
# which risks evicting the REAL production warm cache (parallel = 1 means one shared
# slot — see CLAUDE.md). Prefer QUICK; only use FULL when you specifically need to
# verify end-to-end completion, and be ready to re-run fallback_guard.sh afterward to
# re-warm the real Telegram prompt.
#
# --- 2026-09-23: why this script now uses an isolated HERMES_HOME -------------
# A bogus model name used to be enough: Hermes couldn't resolve its context length,
# fell through every lookup tier, and (on 0.20.x) apparently landed on something
# >= 64K. As of the installed 0.21.3, unresolvable models fall through ALL the way
# to a hardcoded 32,768-token floor (agent/model_metadata.py's DEFAULT_FALLBACK_
# CONTEXT), and agent_init.py's _enforce_minimum_context() now hard-rejects any
# primary model reporting < 64K *before* attempting the request at all — so the
# original bogus-name approach fails at that pre-flight gate and never reaches the
# fallback-routing logic it was designed to exercise. Confirmed empirically: neither
# a plain unrecognized name nor one crafted to substring-match a real model family
# (e.g. containing "gpt-4" or "llama", which DO resolve to real context lengths when
# get_model_context_length() is called directly) helps — something earlier in the
# real CLI/agent-init path still lands on the 32K floor for a model with no live
# catalog entry. Root cause not fully traced beyond that; not worth chasing further
# when there's a clean, documented fix available.
#
# The fix: config.yaml's `model.context_length` is an explicit override — step 0
# in get_model_context_length(), wins unconditionally, no live-catalog dependency.
# There's no CLI flag or env var for it (checked), only config.yaml. Rather than
# touch the LIVE config (never do that for a test), this script builds a throwaway
# HERMES_HOME with its own minimal config.yaml (context_length forced to 65536,
# fallback_model copied from the real config) and copies in the real .env so the
# primary call still hits real OpenRouter with the real key — genuinely exercising
# the real model_not_found classification, not a synthetic shortcut. Verified live:
# the one-shot opened a connection to 127.0.0.1:8080 (the real fallback) within
# seconds, same proof technique as before, now on a foundation that doesn't depend
# on however Hermes happens to resolve context for an unknown model name today.
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

# The model process, found by the alias the router gives it. [x] avoids matching
# this very pgrep invocation's own command line (CLAUDE.md gotcha).
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
    fail "gemma is busy (${busy_pct}% CPU) — probably still digesting an earlier prompt, and this run would queue behind it (identical requests don't share in-flight work — CLAUDE.md). Wait for it to go idle, or FORCE=1."
fi
echo "gemma idle: ${busy_pct}% CPU. mode: $([[ ${FULL} == 1 ]] && echo FULL || echo QUICK), timeout ${TIMEOUT}s"

# --- Build an isolated HERMES_HOME so the pre-flight context-length gate never
# fires, without ever touching the live config.yaml or .env. --------------------
scratch_home="$(mktemp -d)"
cp "${HERMES_HOME}/.env" "${scratch_home}/.env" 2>/dev/null  # real key, never read/printed here
cat > "${scratch_home}/config.yaml" <<EOF
_config_version: 45
model:
  default: ${BOGUS_MODEL}
  provider: openrouter
  context_length: 65536
providers:
  custom:
    base_url: https://openrouter.ai/api/v1
fallback_model:
  provider: custom
  model: ${fb_model}
  base_url: ${fb_url}
  api_key: llama.cpp
fallback_providers: []
EOF

# --- Run the forced failover in the background so we can watch its sockets
usage_file="$(mktemp)"; out_file="$(mktemp)"
trap 'kill "${hpid:-}" 2>/dev/null; rm -f "${usage_file}" "${out_file}"; rm -rf "${scratch_home}"' EXIT
log_lines_before="$(wc -l < "${AGENT_LOG}" 2>/dev/null || echo 0)"

echo "starting one-shot Hermes (isolated HERMES_HOME) with primary model '${BOGUS_MODEL}'..."
start=$(date +%s)
( cd "${HOME}" && HERMES_HOME="${scratch_home}" exec "${HERMES[@]}" -z "${PROMPT}" -m "${BOGUS_MODEL}" --provider openrouter \
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
    echo "FAIL: Hermes never connected to the fallback. Its output:"; echo "${reply:-<none>}"
    echo "(If this is a context-length error again, the pre-flight gate has drifted further — see the 2026-09-23 header note.)"
    exit 1
fi
if [[ "${FULL}" == 1 && "${usage_ok}" != "yes" ]]; then
    echo "FAIL: routed to the fallback but the run did not complete cleanly (timeout ${TIMEOUT}s?)"; exit 1
fi
if [[ "${FULL}" == 1 ]]; then
    [[ "${reply}" == *"FAILOVER-OK"* ]] || echo "  note: reply didn't contain FAILOVER-OK (the model may paraphrase)"
    echo "PASS: failed over to ${fb_model} and completed in ${elapsed}s"
    echo "  Re-run fallback_guard.sh now to re-warm the real Telegram prompt (this test's prompt likely evicted it — parallel=1, one shared slot)."
else
    echo "PASS (quick): Hermes fails over to ${fb_model} in ${t_routed}s — completion not awaited"
    echo "  (gemma may keep digesting the prompt for a while; this can evict the real warm cache — parallel=1, one shared slot."
    echo "  Re-run ~/.hermes/scripts/fallback_guard.sh once gemma goes idle to confirm/restore it.)"
fi
