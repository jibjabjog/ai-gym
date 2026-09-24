#!/usr/bin/env bash
# lib/canon.sh — a character's persistent "canon": the concrete facts it has stated, kept
# across chats, so it looks them up before improvising and cannot quietly contradict itself.
# Sourced by exercise/character.sh (and tests/canon.sh). Findings: FINDINGS.md §12.
#
# Caller provides: char_name, BACKEND, BASE_URL, MODEL_NAME; lib/backend.sh already sourced.
# canon = JSON array of {"f": "<fact>", "k": ["topic","words"]}.
#
#   canon_init <sheet-json>       decide CANON_ON, pick the file, load it
#   canon_save                    write the ledger to disk
#   canon_relevant <question>     JSON array of <=3 fact strings that bear on the question
#   canon_learn <question> <reply>  extract facts from an exchange, dedupe, merge, save
#   canon_contradicts <reply> <facts-json>   prints YES if the reply conflicts with a fact
#
# Env: INKY_CANON=off|<path>  INKY_CANON_MAX=60  INKY_CANON_DEBUG=1  INKY_CANON_CHECK=0 (skip the judge)

CANON_ON=0
CANON_FILE=""
CANON_MAX="${INKY_CANON_MAX:-60}"
canon="[]"

_canon_text() { llm_content "$(llm_message "${BACKEND}" "$1")"; }

# One deterministic, short call: $1 system, $2 user, $3 max tokens -> reply text.
_canon_call() {
    local msgs resp
    msgs="$(jq -n --arg s "$1" --arg u "$2" '[{role: "system", content: $s}, {role: "user", content: $u}]')"
    local LLM_TEMPERATURE=0 LLM_REPEAT_PENALTY=1.0 LLM_MAX_TOKENS="${3:-120}"
    resp="$(llm_chat "${BACKEND}" "${BASE_URL}" "${MODEL_NAME}" "${msgs}")"
    _canon_text "${resp}"
}

canon_init() {
    local sheet="$1"
    CANON_ON=0
    if [[ "${INKY_CANON:-}" != "off" ]] && { [[ -n "${INKY_CANON:-}" ]] || [[ "$(echo "${sheet}" | jq -r '.canon // false')" == "true" ]]; }; then
        CANON_ON=1
    fi
    CANON_FILE="${INKY_CANON:-${HOME}/.local/share/inky/canon-${char_name,,}.json}"
    canon="[]"
    if (( CANON_ON )) && [[ -f "${CANON_FILE}" ]]; then
        # Accepts the first format too (a plain array of strings).
        canon="$(jq -c 'if type == "array" then
                map(if type == "string" then {f: ., k: []}
                    elif type == "object" and ((.f // null) | type) == "string" then {f: .f, k: ((.k // []) | map(select(type == "string")))}
                    else empty end)
              else [] end' "${CANON_FILE}" 2>/dev/null || echo '[]')"
    fi
}

canon_save() {
    (( CANON_ON )) || return 0
    mkdir -p "$(dirname "${CANON_FILE}")" && echo "${canon}" | jq . > "${CANON_FILE}"
}

# Facts that bear on the question, best first (at most 3). Matches on 5-letter stems of the
# fact's own words AND the topic words extracted with it ("quiet" finds "silence"), and treats
# a "when / what time" question as a hint towards facts that contain a time of day.
canon_relevant() {
    (( CANON_ON )) || { echo "[]"; return; }
    jq -n -c --arg q "$1" --argjson canon "${canon}" '
        def stems: ascii_downcase | gsub("[^a-z0-9 ]"; " ") | split(" ")
            | map(select(length >= 4)) | map(select(. as $w
                | ["what","does","that","this","with","have","when","where","which","there","them","then",
                   "they","your","about","were","been","tell","more","would","could","should","from","into",
                   "some","just","like","really","much","many","very","also","again","happened","next"]
                | index($w) | not)) | map(.[0:5]);
        def timefact: test("(\\ba\\.?m\\b|\\bp\\.?m\\b|o.clock|midnight|\\bnoon\\b|\\bdawn\\b|\\bdusk\\b|in the (morning|evening|afternoon)|\\b(after|before|around|at) (one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\\b)"; "i");
        ($q | stems) as $qs
        | ($q | ascii_downcase | test("\\bwhen\\b|what time|which time|what hour|how late|how early")) as $timeq
        | ($canon | map(((.f + " " + ((.k // []) | join(" "))) | stems))) as $all
        | [ $canon[] | . as $c
            | (($c.f + " " + (($c.k // []) | join(" "))) | stems) as $fs
            # a matched word counts 1/(how many facts contain it): a generic word like "night" says less than "drink"
            | ([ $qs[] | select(. as $s | $fs | index($s)) | . as $s | 1 / ([ $all[] | select(index($s)) ] | length) ] | add // 0) as $n
            | ($n + (if $timeq and ($c.f | timefact) then 0.5 else 0 end)) as $score
            | select($score > 0) | {f: $c.f, s: $score} ]
        | sort_by(-.s) | .[0:3] | map(.f)'
}

# Model output -> [{"f": fact, "k": [topic words]}]. One "fact | word, word" per line. Drops NONE,
# "no facts" boilerplate, feelings, over-long lines, and fragments (fewer than 3 words — the extractor
# sometimes emits bare topic words as their own lines, e.g. "Tuesday |").
_canon_parse() {
    printf '%s\n' "$1" | jq -R -s -c '
        split("\n")
        | map(sub("^\\s*([-*•]|[0-9]+[.)])\\s*"; "") | sub("\\s+$"; "")) | map(select(length > 3))
        | map(split(" | ") as $p | {f: ($p[0] | sub("\\s*\\|\\s*$"; "") | sub("\\s+$"; "")),
                                   k: (($p[1] // "") | ascii_downcase | split(",") | map(sub("^\\s+|\\s+$"; "")) | map(select(length > 1)) | .[0:8])})
        | map(select((.f | length) > 3 and (.f | length) <= 160
            and ((.f | split(" ") | length) >= 3)
            and ((.f | test("^none\\.?$"; "i")) | not)
            and ((.f | test("no (concrete|new|specific|hard) fact|nothing concrete|not stated|no facts"; "i")) | not)
            and ((.f | test("\\b(feel|feels|feeling|felt|tired|proud|happy|sad|lonely|bored|angry|mood|emotion)\\b"; "i")) | not)))'
}

# Extract the new concrete facts (+ topic words) from one exchange; merge into canon.
canon_learn() {
    (( CANON_ON )) || return 0
    local q="$1" reply="$2" sys text new added
    sys="You keep the continuity notes for a character called ${char_name}. Read the exchange and list the concrete facts ${char_name} just stated about himself or his world: times, places, names, numbers, objects, events, habits. Only hard specifics someone could later contradict — skip atmosphere, general remarks, sounds and moods. One fact per line, short, plain, third person, followed by ' | ' and 3 to 6 topic words a later question about it might use, including synonyms (for example:  It gets quiet after 2 a.m. | quiet, silence, night, hour, late  /  ${char_name} checks rack seven every hour. | rack, seven, check, hour, round). Only what ${char_name} actually said in his reply. No feelings, opinions or questions. If there is nothing concrete, write NONE."
    text="$(_canon_call "${sys}" "Player: ${q}"$'\n'"${char_name}: ${reply}" 160)"
    [[ -z "${text}" ]] && return 0
    new="$(_canon_parse "${text}")"
    added="$(jq -n -c --argjson old "${canon}" --argjson new "${new}" --argjson cap "${CANON_MAX}" '
        def norm: ascii_downcase | gsub("[^a-z0-9 ]"; "") | gsub("\\s+"; " ");
        def ws: norm | split(" ") | map(select(length > 2)) | unique;
        def similar($a; $b): ($a | ws) as $x | ($b | ws) as $y
            | (($x - ($x - $y)) | length) as $i | (($x + $y) | unique | length) as $u
            | $u > 0 and ($i / $u) >= 0.6;
        reduce $new[] as $n ($old; if any(.[]; similar(.f; $n.f)) then . else . + [$n] end) | .[-$cap:]')"
    if [[ "${INKY_CANON_DEBUG:-0}" == "1" ]]; then
        echo "  [canon +$(jq -n --argjson a "${added}" --argjson o "${canon}" '($a | length) - ($o | length)'): $(echo "${new}" | jq -r 'map(.f + " {" + (.k | join(",")) + "}") | join(" | ")')]"
    fi
    canon="${added}"
    canon_save
}

# Deterministic clock-time check (high precision, no model): the reply and a fact both give a time
# of day, the hours differ, and they talk about the same thing (share a content word). "quiet after
# 2 a.m." vs "quiet around four in the morning" -> conflict. Hours are compared mod 12.
_canon_time_conflict() {
    jq -n -r --arg reply "$1" --argjson facts "$2" '
        def wnum: {"one":1,"two":2,"three":3,"four":4,"five":5,"six":6,"seven":7,"eight":8,"nine":9,"ten":10,"eleven":11,"twelve":12};
        def times: ascii_downcase | [
              (scan("(\\d{1,2})(?::\\d\\d)?\\s?(?:a\\.?m|p\\.?m)") | .[0] | tonumber % 12),
              (scan("\\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\\s+(?:a\\.?m|p\\.?m|in the (?:morning|evening|afternoon)|o.clock)") | wnum[.[0]] % 12),
              (scan("\\b(midnight|noon)\\b") | 0) ] | unique;
        def topic: ascii_downcase | gsub("[^a-z0-9 ]"; " ") | split(" ") | map(select(length >= 4)) | map(.[0:5])
            | map(select(. as $w | ["after","befor","aroun","about","morni","eveni","after","midni","sharp","noon","dawn","dusk",
                "three","four","five","seven","eight","eleve","twelv","tonig","usual","alway","mostl","start"] | index($w) | not))
            | map(select(. as $w | ["gets","goes","been","that","this","with","have","when","what"] | index($w) | not));
        ($reply | times) as $rt | ($reply | topic) as $rs
        | if ($rt | length) == 0 then "NO"
          else (if any($facts[];
                  (. | times) as $ft
                  | ($ft | length) > 0 and (($ft - ($ft - $rt)) | length) == 0
                    and ((( . | topic) - (( . | topic) - $rs)) | length) > 0) then "YES" else "NO" end)
          end'
}

# Does the reply conflict with any of the given facts? Prints YES or NO. Clock times are checked by
# rule first; everything else (numbers, places, names, objects) is left to the model (anything unclear = NO).
canon_contradicts() {
    local reply="$1" facts="$2" sys text
    [[ "$(_canon_time_conflict "${reply}" "${facts}")" == "YES" ]] && { echo YES; return; }
    sys="You check continuity for a character called ${char_name}. Some facts he has already established are listed. Answer YES if his new reply CONFLICTS with any of them (a different time, number, place, name or object for the same thing). Answer NO if it agrees, repeats them, or is about something else. Reply with one word: YES or NO."
    text="$(_canon_call "${sys}" "Established facts:"$'\n'"$(echo "${facts}" | jq -r 'map("- " + .) | join("\n")')"$'\n\n'"New reply: ${reply}" 6)"
    echo "${text}" | tr -d '[:punct:]' | awk '{print toupper($1); exit}' | sed 's/^YES$/YES/; t; s/.*/NO/'
}
