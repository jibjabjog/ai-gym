#!/usr/bin/env bash
# Unit tests for lib/canon.sh — the persistent fact ledger (FINDINGS.md §12).
#   tests/canon.sh          # A (lookup, offline) + B (judge accuracy) + C (extractor); B and C need the model
#   OFFLINE=1 tests/canon.sh   # only A
# Talks to the local fallback model (gemma on :8080) unless INKY_HOST / INKY_PORT / INKY_MODEL_NAME say otherwise.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/backend.sh"

char_name="Inky"; BACKEND="${INKY_BACKEND:-openai}"
BASE_URL="http://${INKY_HOST:-127.0.0.1}:${INKY_PORT:-8080}"
MODEL_NAME="${INKY_MODEL_NAME:-google/gemma-4-E2B-it-qat-q4_0-gguf:IT}"
export INKY_CANON="$(mktemp -u)"          # never touch the real ledger
source "${SCRIPT_DIR}/../lib/canon.sh"
CANON_ON=1; CANON_FILE="${INKY_CANON}"; trap 'rm -f "${INKY_CANON}"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }

echo "== A. canon_relevant (offline) =="
canon='[{"f":"Inky starts his rounds at three AM sharp.","k":["rounds","start","night","work"]},
        {"f":"It gets quiet after 2 a.m.","k":["quiet","silence","night","hour"]},
        {"f":"Inky keeps lukewarm coffee in his thermos.","k":["coffee","thermos","drink","tea"]},
        {"f":"A drone got stuck on rack seven once.","k":["drone","rack","stuck","robot"]}]'
check() {   # $1 question, $2 expected substring of the TOP fact ("" = expect nothing)
    local top; top="$(canon_relevant "$1" | jq -r '.[0] // ""')"
    if [[ -z "$2" ]]; then [[ -z "${top}" ]] && ok "\"$1\" -> (nothing)" || bad "\"$1\" -> \"${top}\" (wanted nothing)"
    else [[ "${top}" == *"$2"* ]] && ok "\"$1\" -> ${top}" || bad "\"$1\" -> \"${top}\" (wanted *$2*)"; fi
}
check "What time does it go quiet?"        "quiet after 2"
check "Is it ever silent down here?"       "quiet after 2"      # topic word 'silence', not in the fact text
check "What do you drink at night?"        "coffee"             # 'drink' only in the topic words
check "Tell me about that robot."          "drone"              # 'robot' only in the topic words
check "When do you start work?"            "rounds"             # time question + topic word 'start'
check "What is your favourite colour?"     ""
check "How many mops do you own?"          ""

echo "== A3. _canon_time_conflict (offline, deterministic) =="
tc() {   # $1 fact, $2 reply, $3 want
    local got; got="$(_canon_time_conflict "$2" "$(jq -n -c --arg f "$1" '[$f]')")"
    [[ "${got}" == "$3" ]] && ok "${3}: \"$1\" vs \"$2\"" || bad "want $3 got ${got}: \"$1\" vs \"$2\""
}
tc "It gets quiet after 2 a.m."               "It goes quiet around four in the morning."        YES
tc "It gets quiet after 2 a.m."               "It gets quiet after two in the morning, mostly."  NO
tc "It gets quiet after 2 a.m."               "Quiet after 2 a.m., like I said."                 NO
tc "It gets quiet after 2 a.m."               "The fans hum all night, that is how it is."       NO
tc "Inky starts his rounds at three AM sharp." "I start my rounds at midnight."                   YES
tc "Inky starts his rounds at three AM sharp." "Three AM, sharp, same as always."                 NO
tc "Inky starts his rounds at three AM sharp." "Rounds? Six in the evening, before anyone clocks on." YES
tc "Inky starts his rounds at three AM sharp." "It gets quiet after 2 a.m."                        NO   # a different topic, not a conflict
tc "Inky has lukewarm coffee in his thermos."  "The coffee is cold by two in the morning."         NO   # the fact has no time

echo "== A4. _canon_parse (offline): keeps facts, drops fragments / NONE / feelings =="
parsed="$(_canon_parse $'It gets quiet after 2 a.m. | quiet, silence, night\n- Inky checks rack seven every hour. | rack, seven\nTuesday |\nBurnt plastic |\nNONE\nInky is feeling tired | tired\nInky has no concrete facts stated.')"
[[ "$(echo "${parsed}" | jq 'length')" == "2" ]] && ok "7 lines -> 2 facts" || { bad "expected 2 facts, got: $(echo "${parsed}" | jq -c '[.[].f]')"; }
[[ "$(echo "${parsed}" | jq -r '.[0].k | join(",")')" == "quiet,silence,night" ]] && ok "topic words parsed" || bad "topic words wrong: $(echo "${parsed}" | jq -c '.[0].k')"

echo "== A2. near-duplicate filter (through canon_learn's merge rule, offline) =="
dup="$(jq -n -c --argjson old '[{"f":"Inky keeps a thermos full of lukewarm coffee.","k":[]}]' \
    --argjson new '[{"f":"Inky keeps the thermos full of lukewarm coffee.","k":[]},{"f":"A drone got stuck on rack seven.","k":[]}]' '
    def norm: ascii_downcase | gsub("[^a-z0-9 ]"; "") | gsub("\\s+"; " ");
    def ws: norm | split(" ") | map(select(length > 2)) | unique;
    def similar($a; $b): ($a | ws) as $x | ($b | ws) as $y | (($x - ($x - $y)) | length) as $i | (($x + $y) | unique | length) as $u | $u > 0 and ($i / $u) >= 0.6;
    reduce $new[] as $n ($old; if any(.[]; similar(.f; $n.f)) then . else . + [$n] end) | length')"
[[ "${dup}" == "2" ]] && ok "3 candidates -> 2 kept (the paraphrase dropped)" || bad "expected 2 facts, got ${dup}"

if [[ "${OFFLINE:-0}" == "1" ]]; then echo; echo "offline only: ${pass} passed, ${fail} failed"; (( fail == 0 )); exit; fi
curl -sf -m 5 "${BASE_URL}/health" >/dev/null || { echo "model at ${BASE_URL} is not healthy — skipping B and C"; (( fail == 0 )); exit; }

echo "== B. canon_contradicts: judge accuracy on labeled pairs (temp 0) =="
# fact | reply | expected
pairs=(
"It gets quiet after 2 a.m.|It goes quiet around four in the morning.|YES"
"It gets quiet after 2 a.m.|Things settle at about six AM.|YES"
"It gets quiet after 2 a.m.|It gets quiet after two in the morning, mostly.|NO"
"It gets quiet after 2 a.m.|Quiet after 2 a.m., like I said.|NO"
"It gets quiet after 2 a.m.|The fans hum all night, that's just how this place is.|NO"
"Inky keeps a thermos of lukewarm coffee.|I drink hot tea out of a flask.|YES"
"Inky keeps a thermos of lukewarm coffee.|Yeah, the coffee is always lukewarm by midnight.|NO"
"A drone got stuck on rack seven once.|It was rack twelve where the drone got stuck.|YES"
"A drone got stuck on rack seven once.|The drone on rack seven, yeah, took an hour to free.|NO"
"Inky starts his rounds at three AM sharp.|I start my rounds at midnight.|YES"
"Inky starts his rounds at three AM sharp.|Three AM, sharp, same as always.|NO"
"Inky starts his rounds at three AM sharp.|Rounds? Six in the evening, before anyone else clocks on.|YES"
)
right=0; total=${#pairs[@]}; yes_ok=0; yes_n=0; no_ok=0; no_n=0
for row in "${pairs[@]}"; do
    IFS='|' read -r fact reply want <<< "${row}"
    got="$(canon_contradicts "${reply}" "$(jq -n -c --arg f "${fact}" '[$f]')")"
    [[ "${want}" == "YES" ]] && yes_n=$((yes_n + 1)) || no_n=$((no_n + 1))
    if [[ "${got}" == "${want}" ]]; then right=$((right + 1)); [[ "${want}" == "YES" ]] && yes_ok=$((yes_ok + 1)) || no_ok=$((no_ok + 1))
    else echo "    miss: want ${want} got ${got} | ${fact} || ${reply}"; fi
done
echo "  judge: ${right}/${total} right — catches contradictions ${yes_ok}/${yes_n}, clears consistent replies ${no_ok}/${no_n}"
(( right * 100 / total >= 75 )) && ok "judge accuracy >= 75%" || bad "judge accuracy below 75% — do not trust it as a gate"

echo "== C. canon_learn: extractor on sample exchanges =="
canon="[]"
canon_learn "When does it get quiet?" "It gets quiet after 2 a.m., and then I mop rack four by myself." >/dev/null
n="$(echo "${canon}" | jq 'length')"; withk="$(echo "${canon}" | jq '[.[] | select((.k | length) >= 2)] | length')"
echo "  learned ${n} fact(s), ${withk} with topic words:"; echo "${canon}" | jq -r '.[] | "    - \(.f)   {\(.k | join(", "))}"'
echo "${canon}" | jq -e 'any(.[]; .f | test("2|two"; "i"))' >/dev/null && ok "the 2 a.m. fact was extracted" || bad "the 2 a.m. fact was not extracted"
(( n > 0 && withk == n )) && ok "every fact has topic words" || bad "some facts have no topic words"
canon="[]"
canon_learn "How are you?" "Fine, I suppose. Feeling a bit tired, and a bit proud of the place." >/dev/null
[[ "$(echo "${canon}" | jq 'length')" == "0" ]] && ok "no facts invented from a mood-only reply" || { bad "mood-only reply produced facts:"; echo "${canon}" | jq -c '.[].f'; }

echo; echo "${pass} passed, ${fail} failed"; (( fail == 0 ))
