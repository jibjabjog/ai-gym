#!/usr/bin/env bash
# Offline unit tests for lib/repeat.sh (fuzzy repeat detection). No model needed.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/repeat.sh"
pass=0; fail=0
t() {   # $1 label, $2 want, $3 reply, $4 own lines (JSON array)
    local got; got="$(near_repeat "$3" "$4")"
    [[ "${got}" == "$2" ]] && { pass=$((pass + 1)); echo "  ok   $1"; } || { fail=$((fail + 1)); echo "  FAIL $1 (want $2 got ${got})"; }
}
own1='["It gets loud when things stop working right and then suddenly everything goes silent again. I usually find about two hours after the last shift ends that’s my window of peace. The main server racks always hum, even if nobody is around to hear them at night."]'
t "recycled opening sentence + new tail (real T5)"      1 "It gets loud when things stop working right and then suddenly everything goes silent again. I usually find about two hours after the last shift ends that’s my window of peace now, though sometimes a distant alarm cuts through." "${own1}"
t "identical reply"                                      1 "It gets loud when things stop working right and then suddenly everything goes silent again." "${own1}"
t "same facts, fresh words"                              0 "Peace comes roughly two hours after the last shift clocks off. Until then the whole floor rattles, and I just keep the mop moving." "${own1}"
own2='["The real silence is usually right before sunrise when things settle down for good. Sometimes I have to wait another hour."]'
t "different answer, same topic (real OFF pair)"         0 "It settles around four in the morning when I finish my sweep of aisle three and make sure all those blinking indicator lights are off for good." "${own2}"
t "short lines are not judged (under 5 words)"           0 "Enough talk for now." '["Enough talk for now."]'
t "no earlier lines"                                     0 "It gets quiet after two in the morning, usually." '[]'
t "one earlier line among many"                          1 "I keep a thermos of lukewarm coffee that I never finish, and I never will." '["Rack four hums.","I keep a thermos of lukewarm coffee that I never finish, and I never will, honestly.","The lights stay on."]'
t "shared stock words only"                              0 "The main cooling fans usually settle into their deepest hum around four, if everything is running right." '["The main server racks always hum, even if nobody is around to hear them at night."]'
echo; echo "${pass} passed, ${fail} failed"; (( fail == 0 ))
