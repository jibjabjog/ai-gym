#!/usr/bin/env bash
# lib/repeat.sh — fuzzy repeat detection: has the character just re-used a sentence (or most of a
# reply) it already said? The exact-match guardrail misses "almost word for word" copies, which is
# what a small model does when its own facts are put in front of it (FINDINGS.md §12c).
#
#   near_repeat <reply> <own-lines-json> [sentence-threshold] [whole-threshold]   prints 1 or 0
#
# A repeat = some sentence of the reply (>= 5 words) overlaps a sentence of an earlier own line by
# >= 0.75 (word-set Jaccard), OR the whole reply overlaps a whole earlier line by >= 0.5.
# Thresholds calibrated on 12 saved T1/T5 pairs: copies scored 0.89-1.00 per sentence / 0.40-0.83 whole;
# genuinely different answers <= 0.50 per sentence / <= 0.49 whole.
#   INKY_NEAR_REPEAT=off disables it (exercise/character.sh)

near_repeat() {
    jq -n -r --arg r "$1" --argjson own "${2:-[]}" --argjson ts "${3:-0.75}" --argjson tw "${4:-0.5}" '
        def ws: ascii_downcase | [scan("[a-z0-9'"'"']+")] | unique;
        def jac($a; $b): (($a | length) + ($b | length)) as $t
            | (($a - ($a - $b)) | length) as $i | ($t - $i) as $u | if $u == 0 then 0 else $i / $u end;
        def sents: [splits("(?<=[.!?])\\s+")] | map(select((ws | length) >= 5));
        ($r | ws) as $rw | ($r | sents) as $rs
        | if any($own[];
              . as $line
              | (($line | ws) as $lw | ($lw | length) >= 6 and ($rw | length) >= 6 and jac($rw; $lw) >= $tw)
                or any($rs[]; . as $a | any(($line | sents)[]; jac(($a | ws); (. | ws)) >= $ts)))
          then 1 else 0 end'
}
