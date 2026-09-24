#!/usr/bin/env bash
# Wear a character sheet: persona, drives, mood dial and a short rolling
# memory, rebuilt into a fresh system "brief" every turn. A bash/jq port of
# ../the-orb's Character Engine (brief.py, guard.py, character.py, guardrail.py).
# Ported (opt-in per sheet, "canon": true): a fact ledger — see "Canon" below. Findings: FINDINGS.md §1, §3, §4.
#   exercise/character.sh                  # interactive
#   exercise/character.sh "one-shot prompt"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/backend.sh"

BASE_URL="http://${INKY_HOST:-127.0.0.1}:${INKY_PORT:-45072}"
BACKEND="${INKY_BACKEND:-openai}"
MODEL_NAME="${INKY_MODEL_NAME:-Inky}"
CHARACTER_SHEET="${INKY_CHARACTER:-${SCRIPT_DIR}/../characters/inky-janitor.json}"
export LLM_MAX_TOKENS="${INKY_MAX_TOKENS:-512}" LLM_THINKING="${INKY_THINKING:-0}"

# the-orb's tuned values: a wider window made small models MORE repetitive.
MAX_MEMORY="${INKY_MEMORY_MAX:-12}"
SHOWN_MEMORY="${INKY_MEMORY_SHOWN:-6}"

if [[ ! -f "${CHARACTER_SHEET}" ]]; then
    echo "FAIL: character sheet not found: ${CHARACTER_SHEET}" >&2
    exit 1
fi
sheet="$(cat "${CHARACTER_SHEET}")"
char_name="$(echo "${sheet}" | jq -r '.name')"

# --- Mood dial (the-orb's Stat + Guard.affiliation) ----------------------
# A bounded value that picks which band of voice examples is shown. Bands,
# directives and vocabularies are sheet data; the mechanism is generic.
mood_value="$(echo "${sheet}" | jq -r '.mood.start')"
mood_floor="$(echo "${sheet}" | jq -r '.mood.floor')"
mood_ceiling="$(echo "${sheet}" | jq -r '.mood.ceiling')"

# Reins, to test one band without scripting a conversation to drift there:
#   INKY_MOOD_TYPE=<band label>  start at that band's threshold (sheet's own labels)
#   INKY_MOOD_SETTING=<n>        start at exactly n (wins over TYPE)
#   INKY_MOOD_LOCK=1             never move from the start value
#   INKY_MOOD_DEBUG=1            print mood + band after each reply
if [[ -n "${INKY_MOOD_TYPE:-}" ]]; then
    band_value="$(echo "${sheet}" | jq -r --arg band "${INKY_MOOD_TYPE}" \
        '(.mood.bands[] | select(.[1] == $band) | .[0]) // empty')"
    if [[ -z "${band_value}" ]]; then
        valid="$(echo "${sheet}" | jq -r '[.mood.bands[][1]] | join(", ")')"
        echo "FAIL: unknown INKY_MOOD_TYPE '${INKY_MOOD_TYPE}'. Valid for this sheet: ${valid}" >&2
        exit 1
    fi
    mood_value="${band_value}"
fi
if [[ -n "${INKY_MOOD_SETTING:-}" ]]; then
    if [[ ! "${INKY_MOOD_SETTING}" =~ ^[0-9]+$ ]]; then
        echo "FAIL: INKY_MOOD_SETTING must be a whole number (${mood_floor}-${mood_ceiling}), got '${INKY_MOOD_SETTING}'" >&2
        exit 1
    fi
    mood_value="${INKY_MOOD_SETTING}"
fi
(( mood_value < mood_floor )) && mood_value=${mood_floor}
(( mood_value > mood_ceiling )) && mood_value=${mood_ceiling}
MOOD_LOCK="${INKY_MOOD_LOCK:-0}"
MOOD_DEBUG="${INKY_MOOD_DEBUG:-0}"

# Ascending (threshold, label) bands: the first band at or above the value, else the last.
current_band() {
    echo "${sheet}" | jq -r --argjson v "${mood_value}" '
        .mood.bands as $bands
        | ([$bands[] | select($v <= .[0])] | first) // $bands[-1]
        | .[1]
    '
}

mood_directive() {
    local band="$1"
    echo "${sheet}" | jq -r --arg band "${band}" '.mood.directives[$band]'
}

# Negation-aware keyword scoring (the-orb's has_unnegated_match): without it,
# "I'm not a threat to anyone" docks mood for menace it doesn't contain.
NEGATION_WORDS_JSON='["not","no","never","don'"'"'t","doesn'"'"'t","didn'"'"'t","isn'"'"'t","aren'"'"'t","wasn'"'"'t","weren'"'"'t","won'"'"'t","wouldn'"'"'t","can'"'"'t","couldn'"'"'t","ain'"'"'t"]'
NEGATION_WINDOW=3

player_lines_json() {
    echo "${memory}" | jq '[.[] | select(startswith("player: ")) | .[8:]]'
}

# Mood delta for one player line: kind/rude/threat words (negation-aware),
# phrases (substring), plus a penalty for repeating an earlier line. Must run
# before the line joins memory, or the repeat check matches the line itself.
mood_delta_for_text() {
    local utterance="$1"
    echo "${sheet}" | jq -r \
        --arg utterance "${utterance}" \
        --argjson negations "${NEGATION_WORDS_JSON}" \
        --argjson window "${NEGATION_WINDOW}" \
        --argjson prior "$(player_lines_json)" '
        .mood as $mood
        | ($utterance | ascii_downcase) as $lowered
        | ($lowered | [scan("[a-z'\'']+")]) as $tokens
        | ($tokens | length) as $n
        | def has_unnegated_match(triggers):
            [range(0; $n)]
            | any(
                . as $i
                | ($tokens[$i]) as $t
                | (triggers | index($t)) != null
                  and (
                    [range((if ($i - $window) < 0 then 0 else ($i - $window) end); $i)]
                    | map($tokens[.])
                    | any(. as $w | $negations | index($w) != null)
                    | not
                  )
              );
        def has_phrase(phrases): any(phrases[]; . as $p | $lowered | contains($p));
        def is_repeat: any($prior[]; . as $p | ($p | ascii_downcase) == $lowered);
        (if has_unnegated_match($mood.kind_words) then $mood.deltas.kind else 0 end)
        + (if (has_unnegated_match($mood.rude_words) or has_phrase($mood.rude_phrases)) then $mood.deltas.rude else 0 end)
        + (if (has_unnegated_match($mood.threat_words) or has_phrase($mood.threat_phrases)) then $mood.deltas.threat else 0 end)
        + (if is_repeat then $mood.deltas.repeat else 0 end)
    '
}

adjust_mood_from_text() {
    [[ "${MOOD_LOCK}" == "1" ]] && return
    local delta
    delta="$(mood_delta_for_text "$1")"
    mood_value=$(( mood_value + delta ))
    (( mood_value < mood_floor )) && mood_value=${mood_floor}
    (( mood_value > mood_ceiling )) && mood_value=${mood_ceiling}
}

# --- Canon: facts the character has stated, kept across chats (lib/canon.sh) ---
# After every reply the concrete facts are extracted and saved; every brief carries all canon
# plus the lines relevant to THIS question; and a reply that contradicts a relevant fact is
# redone (never saved). Opt-in per sheet ("canon": true) or with INKY_CANON=<path>.
#   INKY_CANON=off|<path>   INKY_CANON_MAX=60   INKY_CANON_DEBUG=1   INKY_CANON_CHECK=0 (skip the judge)
#   in chat: /canon lists the facts, /forget wipes them
source "${SCRIPT_DIR}/../lib/canon.sh"
canon_init "${sheet}"

# JSON array of "speaker: line" strings, oldest first, capped at MAX_MEMORY.
memory="[]"

remember() {
    local speaker="$1" line="$2"
    memory="$(echo "${memory}" | jq --arg entry "${speaker}: ${line}" \
        --argjson cap "${MAX_MEMORY}" '(. + [$entry])[-$cap:]')"
}

# Sheet + current band + recent memory -> one system message. The mood line
# goes last: the highest-attention position, as in the-orb.
build_brief() {
    local band directive
    band="$(current_band)"
    directive="$(mood_directive "${band}")"
    echo "${sheet}" | jq -r \
        --argjson memory "${memory}" --argjson shown "${SHOWN_MEMORY}" \
        --argjson canon "${canon}" --argjson relevant "$(canon_relevant "${CURRENT_Q:-}")" \
        --arg band "${band}" --arg directive "${directive}" '
        . as $sheet
        | ($sheet.persona | gsub("\\{name\\}"; $sheet.name)) as $persona
        | (.voice_examples.by_band[$band] // .voice_examples.by_band[(.voice_examples.by_band | keys[0])]) as $band_examples
        | [
            $persona,
            "",
            "# Examples of your voice (style only — not this scene, don'\''t reuse the lines)",
            ($band_examples[]),
            (.voice_examples.always[]),
            "",
            "# What'\''s on your mind",
            (.drives[] | "- You are " + .),
            "",
            "# Your private history",
            "(This is why you are how you are — background, never something you'\''d recite out loud.)",
            ("- " + .backstory)
          ]
          + (if ($canon | length) > 0 then
                ["", "# Facts you have already established (things you have actually said — stay consistent, never contradict them; if asked about one of these, answer from it; anything NOT listed you may still invent, then it becomes fact)"]
                + ($canon | map("- " + .f))
              else [] end)
          + (
              ($memory[-$shown:]) as $recent
              | if ($recent | length) > 0 then
                  ["", "# What'\''s been said so far"] + ($recent | map("- " + .))
                else [] end
            )
          + (if ($relevant | length) > 0 then
                ["", "# You have ALREADY said this, relevant to what they just asked — answer consistently with it, do not change it"]
                + ($relevant | map("- " + .))
              else [] end)
          + [
              "",
              "# Your mood right now — this overrides your general nature above if they ever conflict",
              ("You feel " + $band + ": " + $directive),
              .rule_reminder
            ]
        | join("\n")
    '
}

# Each turn is a single call: system = brief (memory folded in), user = latest line.
# Server defaults let small models ramble and loop, so sampling is tightened.
TEMPERATURE="${INKY_TEMPERATURE:-0.4}"
REPEAT_PENALTY="${INKY_REPEAT_PENALTY:-1.3}"
# The guardrail retry resamples hotter: at the same low temperature it can
# reproduce the exact line it's escaping.
RETRY_TEMPERATURE="${INKY_RETRY_TEMPERATURE:-1.0}"
export LLM_REPEAT_PENALTY="${REPEAT_PENALTY}"

# mode: "default" or "retry" — only changes which temperature is used.
send() {
    local brief="$1" utterance="$2" mode="${3:-default}" messages
    local LLM_TEMPERATURE="${TEMPERATURE}"   # dynamically scoped: llm_chat sees it
    [[ "${mode}" == "retry" ]] && LLM_TEMPERATURE="${RETRY_TEMPERATURE}"
    messages="$(jq -n --arg s "${brief}" --arg u "${utterance}" '[{role: "system", content: $s}, {role: "user", content: $u}]')"
    llm_chat "${BACKEND}" "${BASE_URL}" "${MODEL_NAME}" "${messages}"
}

reply_content() { llm_content "$(llm_message "${BACKEND}" "$1")"; }
print_reply()   { llm_display "${char_name}" "${BACKEND}" "$1"; }

# --- Anti-repetition guardrail (the-orb's guardrail.py + loop.py retry) ---
# Catches a near-verbatim echo of the character's own line or of a voice
# example; resamples once with a nudge, else ships the sheet's fallback line.
# the-orb's scene-specific checks (bland dismissal, room description) not ported.

REPEAT_NUDGE=$'\n\n# Note\nYour last instinct was to repeat something you already said, word for word — resist it. React fresh to what they just said, even if the sentiment ends up similar.'
VOICE_EXAMPLE_NUDGE=$'\n\n# Note\nYour last instinct was to answer with the exact words from the voice examples above — resist it. Those show your voice, not your actual line. Say something different that still sounds like you.'

own_lines_json() {
    local prefix="${char_name,,}: "
    echo "${memory}" | jq --arg prefix "${prefix}" \
        '[.[] | select(startswith($prefix)) | .[($prefix | length):]]'
}

# Reply halves of every voice example, across all bands (not just the one shown).
voice_example_replies_json() {
    echo "${sheet}" | jq '
        (.voice_examples.always + ([.voice_examples.by_band[]] | add))
        | map(capture("-> You: \"(?<r>.*)\"\\s*$").r)
    '
}

# Echoes "self_repeat", "voice_example", or "" — ignoring case, quotes, trailing punctuation.
classify_failure() {
    local reply="$1"
    jq -n -r \
        --arg reply "${reply}" \
        --argjson own "$(own_lines_json)" \
        --argjson examples "$(voice_example_replies_json)" '
        def norm: ascii_downcase | gsub("^[\\s\"]+|[\\s\"]+$"; "") | gsub("[.!?…]+$"; "");
        ($reply | norm) as $r
        | if ($own | map(norm) | index($r)) then "self_repeat"
          elif ($examples | map(norm) | index($r)) then "voice_example"
          else "" end
    '
}

# Must be first-person dialogue: third-person narration ("Inky just keeps
# working…") is itself a persona violation (FINDINGS.md §4).
fallback_line() {
    echo "${sheet}" | jq -r --arg name "${char_name}" \
        '(.fallback_line // "Nothing more to say right now.") | gsub("\\{name\\}"; $name)'
}

# One turn. Order matters: mood moves and the player line joins memory
# BEFORE the brief is built, so the brief reflects the mood this line caused.
ask_and_record() {
    local user_line="$1"
    local brief response content failure note=""

    CURRENT_Q="${user_line}"
    adjust_mood_from_text "${user_line}"
    remember "player" "${user_line}"

    brief="$(build_brief)"
    # INKY_CANON_REMIND=1 (off by default; no measurable gain in §12): also put the relevant established facts in the user turn,
    # where a small model pays most attention (system-prompt canon alone can be overlooked).
    local utter="${user_line}" rel
    if (( CANON_ON )) && [[ "${INKY_CANON_REMIND:-0}" == "1" ]]; then
        rel="$(canon_relevant "${user_line}" | jq -r 'join(" ")')"
        [[ -n "${rel}" ]] && utter="${user_line}"$'\n\n'"(You already told them: ${rel} Stay consistent with that.)"
    fi
    response="$(send "${brief}" "${utter}" "default")"
    content="$(reply_content "${response}")"
    failure=""
    [[ -n "${content}" ]] && failure="$(classify_failure "${content}")"

    if [[ -n "${failure}" ]]; then
        local nudge retry_failure
        if [[ "${failure}" == "voice_example" ]]; then
            nudge="${VOICE_EXAMPLE_NUDGE}"
        else
            nudge="${REPEAT_NUDGE}"
        fi
        response="$(send "${brief}${nudge}" "${utter}" "retry")"
        content="$(reply_content "${response}")"
        retry_failure=""
        [[ -n "${content}" ]] && retry_failure="$(classify_failure "${content}")"

        if [[ -n "${retry_failure}" || -z "${content}" ]]; then
            content="$(fallback_line)"
            note=" [guardrail: ${failure}, fallback]"
        else
            note=" [guardrail: ${failure}, retried]"
        fi
    fi

    # Continuity: a reply that conflicts with a relevant established fact is redone once, with the
    # fact as a nudge. A reply that still conflicts is shown but never learned.
    local skip_learn=0 relq c2
    if (( CANON_ON )) && [[ "${INKY_CANON_CHECK:-1}" == "1" && -n "${content}" && "${note}" != *fallback* ]]; then
        relq="$(canon_relevant "${user_line}")"
        if [[ "${relq}" != "[]" && "$(canon_contradicts "${content}" "${relq}")" == "YES" ]]; then
            local cnudge=$'\n\n# Note\nYour last answer CONTRADICTED something you already told them:\n'"$(echo "${relq}" | jq -r 'map("- " + .) | join("\n")')"$'\nAnswer again so it agrees with that — do not change the facts.'
            response="$(send "${brief}${cnudge}" "${utter}" "default")"
            c2="$(reply_content "${response}")"
            if [[ -n "${c2}" ]]; then
                content="${c2}"
                if [[ "$(canon_contradicts "${content}" "${relq}")" == "YES" ]]; then
                    note="${note} [guardrail: contradiction, unresolved]"; skip_learn=1
                else
                    note="${note} [guardrail: contradiction, retried]"
                fi
            else
                note="${note} [guardrail: contradiction, unresolved]"; skip_learn=1
            fi
        fi
    fi

    if [[ -n "${note}" ]]; then
        echo "${char_name}> ${content}${note}"
    else
        print_reply "${response}"
    fi
    [[ "${MOOD_DEBUG}" == "1" ]] && echo "  [mood: ${mood_value} ($(current_band))]"

    [[ -n "${content}" ]] && remember "${char_name,,}" "${content}"
    # Learn from what he really said — not from the guardrail's canned fallback line.
    [[ -n "${content}" && "${note}" != *fallback* && "${skip_learn}" == 0 ]] && canon_learn "${user_line}" "${content}"
}

if [[ $# -gt 0 ]]; then
    # Single-shot mode.
    ask_and_record "$*"
    exit 0
fi

# Interactive mode.
echo "Talking with ${char_name} at ${BASE_URL} (sheet: ${CHARACTER_SHEET}; type 'exit' or Ctrl-D to quit$( ((CANON_ON)) && echo "; /canon lists what ${char_name} has established, /forget wipes it"))"
while true; do
    read -r -p "you> " line || { echo; break; }
    [[ -z "${line}" ]] && continue
    [[ "${line}" == "exit" || "${line}" == "quit" ]] && break
    if [[ "${line}" == "/canon" ]]; then
        if (( CANON_ON )); then echo "${canon}" | jq -r 'if length == 0 then "(nothing established yet)" else map("- " + .f + (if (.k | length) > 0 then "   {" + (.k | join(", ")) + "}" else "" end))[] end'; else echo "(canon is off for this sheet)"; fi
        continue
    fi
    if [[ "${line}" == "/forget" ]]; then canon="[]"; (( CANON_ON )) && rm -f "${CANON_FILE}"; echo "(canon wiped)"; continue; fi

    ask_and_record "${line}"
done
