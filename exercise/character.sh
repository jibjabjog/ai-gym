#!/usr/bin/env bash
# Give Inky a personality: a persona, a backstory, drives, a mood dial, and
# a short rolling memory, all rebuilt into a fresh system-message "brief"
# before every reply — same pattern as ../the-orb's Character Engine
# (engine/brief.py's build_guard_brief, engine/guard.py's Guard, engine/
# character.py's Stat), just hand-rolled in jq instead of depending on that
# project's Python engine.
#
# Still not ported: the-orb's LLM fact-extraction call to pin down
# improvised details as permanent canon (Guard.add_established_fact) —
# persona + mood + short memory is as far as this v1 goes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INKY_HOST="${INKY_HOST:-127.0.0.1}"
INKY_PORT="${INKY_PORT:-45072}"
BASE_URL="http://${INKY_HOST}:${INKY_PORT}"
MAX_TOKENS="${INKY_MAX_TOKENS:-512}"
THINKING="${INKY_THINKING:-0}"
CHARACTER_SHEET="${INKY_CHARACTER:-${SCRIPT_DIR}/../characters/inky-janitor.json}"
MODEL_NAME="${INKY_MODEL_NAME:-Inky}"
# "openai" talks to a llama.cpp-style /v1/chat/completions server (Inky's
# native API). "ollama" talks to ollama's own /api/chat instead — its
# OpenAI-compat endpoint ignores the thinking toggle entirely, only the
# native API respects `think` (found evaluating spark-x2.5, 2026-09-16,
# see CLAUDE.md).
BACKEND="${INKY_BACKEND:-openai}"

# Tuned values the-orb arrived at the hard way (engine/guard.py): a wider
# memory window made their small model MORE verbatim-repetitive, not less
# — "forgetting old chats is in character for a low-level NPC." Cap what's
# kept, show fewer than that.
MAX_MEMORY=12
SHOWN_MEMORY=6

if [[ ! -f "${CHARACTER_SHEET}" ]]; then
    echo "FAIL: character sheet not found: ${CHARACTER_SHEET}" >&2
    exit 1
fi
sheet="$(cat "${CHARACTER_SHEET}")"
char_name="$(echo "${sheet}" | jq -r '.name')"

# --- Mood dial (the-orb's engine/character.py's Stat + engine/guard.py's
# Guard.affiliation, ported) ----------------------------------------------
#
# A bounded, fluctuating attribute driving which band of voice_examples
# gets shown — the actual fix for tonal sameness (a static voice-example
# block anchors tone too strongly regardless of what the guardrail catches;
# the-orb's own finding, see CLAUDE.md). Sheet-defined bands/directives/
# word lists (NPC-owned data); the mechanism itself (Stat's clamp+band
# lookup, has_unnegated_match's negation-aware scoring) is generic below.
mood_value="$(echo "${sheet}" | jq -r '.mood.start')"
mood_floor="$(echo "${sheet}" | jq -r '.mood.floor')"
mood_ceiling="$(echo "${sheet}" | jq -r '.mood.ceiling')"

# Ascending (threshold, label) bands — mirrors Stat.band: first band whose
# threshold the value is at or under, else the last band.
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

# Same NEGATION_WORDS/NEGATION_WINDOW as engine/character.py's
# has_unnegated_match — a real false positive there ("I'm not a threat to
# anyone") is exactly why this exists: pure keyword membership without a
# sense of what came before the word docks mood for reassurance, not menace.
NEGATION_WORDS_JSON='["not","no","never","don'"'"'t","doesn'"'"'t","didn'"'"'t","isn'"'"'t","aren'"'"'t","wasn'"'"'t","weren'"'"'t","won'"'"'t","wouldn'"'"'t","can'"'"'t","couldn'"'"'t","ain'"'"'t"]'
NEGATION_WINDOW=3

# Player's own past lines, unprefixed — same shape as own_lines_json below,
# used for the repeat-delta check (adjust_affiliation_from_text's was_repeat).
player_lines_json() {
    echo "${memory}" | jq '[.[] | select(startswith("player: ")) | .[8:]]'
}

# Scores `utterance` against the sheet's kind/rude/threat vocabulary
# (negation-aware for single words, plain substring for phrases — same
# split as adjust_affiliation_from_text) plus a repeat-of-player's-own-line
# check, and returns the total delta to apply to mood_value. Must run
# BEFORE this utterance joins memory (see ask_and_record) — the-orb's own
# comment: "Check for a repeat against prior turns before this one joins
# memory."
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
    local delta
    delta="$(mood_delta_for_text "$1")"
    mood_value=$(( mood_value + delta ))
    (( mood_value < mood_floor )) && mood_value=${mood_floor}
    (( mood_value > mood_ceiling )) && mood_value=${mood_ceiling}
}

# memory is a flat JSON array of "Speaker: line" strings, oldest first,
# capped at MAX_MEMORY — mirrors Guard.remember()/recent_memory().
memory="[]"

remember() {
    local speaker="$1" line="$2"
    memory="$(echo "${memory}" | jq --arg entry "${speaker}: ${line}" \
        --argjson cap "${MAX_MEMORY}" '(. + [$entry])[-$cap:]')"
}

# Walks the character sheet + current mood band + recent memory into a
# markdown system message — the brief-builder, same shape as
# build_guard_brief but for one NPC.
build_brief() {
    local band directive
    band="$(current_band)"
    directive="$(mood_directive "${band}")"
    echo "${sheet}" | jq -r \
        --argjson memory "${memory}" --argjson shown "${SHOWN_MEMORY}" \
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
          + (
              ($memory[-$shown:]) as $recent
              | if ($recent | length) > 0 then
                  ["", "# What'\''s been said so far"] + ($recent | map("- " + .))
                else [] end
            )
          + [
              "",
              ("# Right now you feel " + $band + " — " + $directive),
              .rule_reminder
            ]
        | join("\n")
    '
}

# POSTs the brief + latest utterance as a single-turn call (system + one
# user message) — not the full chat history. Memory is folded into the
# brief text itself above, same as the-orb's llm.ask(prompt, system=brief).
#
# Lower temperature / added repeat_penalty vs the server's defaults
# (0.8 temp, no repeat penalty): at defaults this 0.8B model would go on
# tangents ("I've been drinking more than anyone else has" — unprompted)
# and loop on one stock phrase turn after turn. Grounded, in-character
# replies matter more here than creative variety.
TEMPERATURE="${INKY_TEMPERATURE:-0.4}"
REPEAT_PENALTY="${INKY_REPEAT_PENALTY:-1.3}"
# Used only for the one guardrail retry below — deliberately more diverse
# than TEMPERATURE, same reasoning as the-orb's RETRY_SAMPLER_CONFIG_KWARGS
# (engine/llm.py): a resample at the same low temperature is close enough
# to deterministic that it can reproduce the exact repeated line it was
# meant to escape.
RETRY_TEMPERATURE="${INKY_RETRY_TEMPERATURE:-1.0}"

# mode: "default" or "retry" — only changes which temperature is used.
send() {
    local brief="$1" utterance="$2" mode="${3:-default}"
    local enable_thinking="false"
    [[ "${THINKING}" == "1" ]] && enable_thinking="true"
    local temperature="${TEMPERATURE}"
    [[ "${mode}" == "retry" ]] && temperature="${RETRY_TEMPERATURE}"

    if [[ "${BACKEND}" == "ollama" ]]; then
        curl -s -m 120 "${BASE_URL}/api/chat" \
            -H "Content-Type: application/json" \
            -d "$(jq -n \
                --arg system "${brief}" \
                --arg user "${utterance}" \
                --argjson num_predict "${MAX_TOKENS}" \
                --argjson think "${enable_thinking}" \
                --argjson temperature "${temperature}" \
                --argjson repeat_penalty "${REPEAT_PENALTY}" \
                --arg model "${MODEL_NAME}" \
                '{model: $model, messages: [{role: "system", content: $system}, {role: "user", content: $user}],
                  think: $think, stream: false,
                  options: {num_predict: $num_predict, temperature: $temperature, repeat_penalty: $repeat_penalty}}')"
    else
        curl -s -m 120 "${BASE_URL}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$(jq -n \
                --arg system "${brief}" \
                --arg user "${utterance}" \
                --argjson max_tokens "${MAX_TOKENS}" \
                --argjson enable_thinking "${enable_thinking}" \
                --argjson temperature "${temperature}" \
                --argjson repeat_penalty "${REPEAT_PENALTY}" \
                --arg model "${MODEL_NAME}" \
                '{model: $model, messages: [{role: "system", content: $system}, {role: "user", content: $user}],
                  max_tokens: $max_tokens, temperature: $temperature, repeat_penalty: $repeat_penalty,
                  chat_template_kwargs: {enable_thinking: $enable_thinking}}')"
    fi
}

reply_content() {
    if [[ "${BACKEND}" == "ollama" ]]; then
        echo "$1" | jq -r '.message.content // empty'
    else
        echo "$1" | jq -r '.choices[0].message.content // empty'
    fi
}

# Prints the display line for a response, falling back to reasoning if the
# visible content came back empty (generation cut off mid-thought).
print_reply() {
    local response="$1" content reasoning
    content="$(reply_content "${response}")"
    if [[ -n "${content}" ]]; then
        echo "${char_name}> ${content}"
    else
        if [[ "${BACKEND}" == "ollama" ]]; then
            reasoning="$(echo "${response}" | jq -r '.message.thinking // empty')"
        else
            reasoning="$(echo "${response}" | jq -r '.choices[0].message.reasoning_content // empty')"
        fi
        if [[ -n "${reasoning}" ]]; then
            echo "${char_name}> (no reply yet, still reasoning) ${reasoning}"
        else
            echo "${char_name}> [empty response] $(echo "${response}" | jq -c '.error // .')"
        fi
    fi
}

# --- Anti-repetition guardrail (the-orb's engine/guardrail.py + the retry
# logic in engine/loop.py's _ask_and_record, ported to bash) -------------
#
# Two things a small model reliably does under this harness (live-tested,
# both here and in the-orb's own devlog): echo one of its own past lines
# verbatim turn after turn, or copy a voice-example line outright instead
# of treating it as a style reference. Neither is "a rewrite" — it's
# "resample once, and if that also fails, ship a safe static line instead
# of the same bad reply twice." Deliberately not porting the-orb's other
# guardrail checks (bland-dismissal, room-description) — those are tied to
# their dungeon/guard scenario, not generic.

REPEAT_NUDGE=$'\n\n# Note\nYour last instinct was to repeat something you already said, word for word — resist it. React fresh to what they just said, even if the sentiment ends up similar.'
VOICE_EXAMPLE_NUDGE=$'\n\n# Note\nYour last instinct was to answer with the exact words from the voice examples above — resist it. Those show your voice, not your actual line. Say something different that still sounds like you.'

# This character's own past lines, unprefixed — the repeat check compares
# against these, not the raw "name: line" memory entries.
own_lines_json() {
    local prefix="${char_name,,}: "
    echo "${memory}" | jq --arg prefix "${prefix}" \
        '[.[] | select(startswith($prefix)) | .[($prefix | length):]]'
}

# The reply half of each "- Player: "..." -> You: "..."" voice example,
# across EVERY mood band plus the always-shown set — not just the band in
# play this turn. Cheap extra coverage, matching the-orb's own
# VOICE_EXAMPLE_REPLIES comment: no downside to checking against examples
# that happen not to be shown this particular turn.
voice_example_replies_json() {
    echo "${sheet}" | jq '
        (.voice_examples.always + ([.voice_examples.by_band[]] | add))
        | map(capture("-> You: \"(?<r>.*)\"\\s*$").r)
    '
}

# Echoes "self_repeat", "voice_example", or "" (empty = passes clean).
# Case/whitespace/quote/trailing-punctuation-insensitive, same spirit as
# guardrail.py's is_repeated_reply — a near-verbatim echo counts, not just
# an exact byte match.
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

# A safe static line to ship instead of a second bad reply in a row —
# guardrail.py's fallback_line(), made per-character via the sheet. Must be
# first-person in-character dialogue, not third-person narration — the-orb
# hit exactly this bug live (2026-09-16, guardrail.py): a shared "The guard
# grunts, and says nothing more." line was itself a persona violation
# (third-person narration voiced as the guard's own line, when only the DM
# narrates in third person). Caught here the same day by noticing their fix
# and checking this sheet's default against it — it had the identical bug.
fallback_line() {
    echo "${sheet}" | jq -r --arg name "${char_name}" \
        '(.fallback_line // "Nothing more to say right now.") | gsub("\\{name\\}"; $name)'
}

# One turn end to end: adjust mood from what was just said, build the
# brief, ask, guardrail-check, retry once with a nudge on failure, fall
# back to a safe line if the retry also fails — then record both sides of
# the exchange into memory and print. Mood must move (and the player's line
# must join memory) BEFORE build_brief, both for the same reason: the
# repeat-delta check needs to compare against PRIOR turns, and the brief
# needs to reflect the mood *this* line just caused — see the-orb's
# run_turn: "Check for a repeat against prior turns before this one joins
# memory."
ask_and_record() {
    local user_line="$1"
    local brief response content failure note=""

    adjust_mood_from_text "${user_line}"
    remember "player" "${user_line}"

    brief="$(build_brief)"
    response="$(send "${brief}" "${user_line}" "default")"
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
        response="$(send "${brief}${nudge}" "${user_line}" "retry")"
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

    if [[ -n "${note}" ]]; then
        echo "${char_name}> ${content}${note}"
    else
        print_reply "${response}"
    fi

    [[ -n "${content}" ]] && remember "${char_name,,}" "${content}"
}

if [[ $# -gt 0 ]]; then
    # Single-shot mode.
    ask_and_record "$*"
    exit 0
fi

# Interactive mode.
echo "Talking with ${char_name} at ${BASE_URL} (sheet: ${CHARACTER_SHEET}; type 'exit' or Ctrl-D to quit)"
while true; do
    read -r -p "you> " line || { echo; break; }
    [[ -z "${line}" ]] && continue
    [[ "${line}" == "exit" || "${line}" == "quit" ]] && break

    ask_and_record "${line}"
done
