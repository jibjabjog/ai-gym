#!/usr/bin/env bash
# Discover and report on every AI reachable from this box — the local ones the
# gym exercises, plus the frontier model Hermes is currently routed to.
#
# Read-only by design. It never sends a completion: firing a request at gemma on
# :8080 would evict the warm prompt cache (see CLAUDE.md / FINDINGS §11), so this
# only queries /health, /props, /v1/models, /api/tags, /api/ps and reads the
# freerouter selection file. For speed numbers use tests/bench.sh.
#
# The frontier (OpenRouter / freerouter) model is *reported*, not probed: a live
# probe needs OPENROUTER_API_KEY, which lives in ~/.hermes/.env (off-limits).
# Probe it live from the GUI instead — it holds your pasted key. Its "Discover"
# button does exactly that.
#
#   tests/discover.sh                    # report to stdout + results/<date>-discover.txt
#   ROUTER_PORT=8080 OLLAMA_PORT=11434 tests/discover.sh
set -uo pipefail

HOST="${INKY_HOST:-127.0.0.1}"
ROUTER_PORT="${ROUTER_PORT:-8080}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
SELECTION_FILE="${SELECTION_FILE:-$HOME/.hermes/.model_selection.json}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="${REPO_DIR}/results/$(date +%F)-discover.txt"

# Everything below is teed to the results file.
{
echo "===================================================================="
echo " Inky's Gym — AI discovery report"
echo " $(date -Is)   host ${HOST}"
echo "===================================================================="

# ---- 1. llama-router (gemma / the live 'inky' fallback) --------------------
RB="http://${HOST}:${ROUTER_PORT}"
echo
echo "== llama-router  ${RB}  (Hermes' live fallback) =="
if curl -sf -m 5 "${RB}/health" >/dev/null 2>&1; then
    echo "status:       UP"
    # /props is router-level noise under --models-max 1; take context from
    # /v1/models meta instead (per-model n_ctx_train).
    busy="$(curl -s -m 5 "${RB}/slots" | jq -r '[.[] | select(.is_processing)] | length' 2>/dev/null)"
    echo "busy slots:   ${busy:-unknown}  (a busy model is still healthy — don't restart)"
    echo "models:"
    curl -s -m 5 "${RB}/v1/models" | jq -r '.data[] | "  - \(.id)  ctx=\(.meta.n_ctx_train // "?")"' 2>/dev/null
else
    echo "status:       DOWN  (this is Hermes' live fallback — check llama-router.service)"
fi

# ---- 2. ollama (spark models) ---------------------------------------------
OB="http://${HOST}:${OLLAMA_PORT}"
echo
echo "== ollama  ${OB} =="
if curl -sf -m 5 "${OB}/api/tags" >/dev/null 2>&1; then
    echo "status:       UP"
    echo "installed:"
    curl -s -m 5 "${OB}/api/tags" | jq -r '.models[] | "  - \(.name)  \((.size/1e9)|floor)GB  \(.details.parameter_size // "?")"' 2>/dev/null
    loaded="$(curl -s -m 5 "${OB}/api/ps" | jq -r '.models[]?.name' 2>/dev/null)"
    echo "loaded now:   ${loaded:-none (loads on demand, unloads when idle)}"
else
    echo "status:       DOWN  (is ollama.service running?)"
fi

# ---- 3. Hermes frontier (freerouter's OpenRouter pick) --------------------
echo
echo "== Hermes frontier  (freerouter's OpenRouter selection) =="
echo "note:         reported read-only; live probe = the GUI's Discover button (holds the key)"
if [[ -r "${SELECTION_FILE}" ]]; then
    echo "selection:    ${SELECTION_FILE}"
    jq -r '
        "updated:      \(.updated)   dry_run=\(.dry_run)",
        "primary pick:",
        (.selected.main // [] | to_entries[] | "  \(if .key==0 then "->" else "  " end) \(.value.id)  ctx=\(.value.context_length)  score=\(.value.aggregate|floor)  healthy=\(.value.healthy)")
    ' "${SELECTION_FILE}" 2>/dev/null || echo "  (could not parse selection JSON)"
else
    echo "selection:    not found / not readable at ${SELECTION_FILE}"
fi

echo
echo "-- end report --"
} | tee "${OUT_FILE}"

echo
echo "saved: ${OUT_FILE}"
