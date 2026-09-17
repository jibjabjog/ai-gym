# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose (from README.md)

A gym for testing "Inky the janitor AI" — Inky is a stand-in name for any AI under test, defaulting to the local Hermes failover called "Inky". Two planned areas:

- **Tests** (`tests/`): scripts to verify Inky is running OK and measure tokens/second.
- **Exercise** (`exercise/`): scripts to exercise Inky — a simple chat-starter script, a script to explore Inky's capabilities and specification, a character-harness script that gives Inky a persistent persona, and an arena-style interview script that compares candidate models for the Inky role.

## What "Inky" is

Inky is the alias of the `llama-qwen35-tiny.service` systemd `--user` unit: a `llama.cpp` server (`llama-server`) bound to `127.0.0.1:45072`, serving `Qwen3.5-0.8B-Q4_K_M.gguf` as the local failover model for the Hermes Agent's `fallback_model` (see `~/.hermes/config.yaml`). It exposes both an OpenAI-compatible API (`/v1/...`) and llama.cpp's native API (`/health`, `/completion`, `/props`), all unauthenticated on loopback.

This is a separate process from the Hermes Agent gateway itself (`hermes-gateway.service`) and from the multi-model `llama-router.service` (port 8080) — Inky only comes into play when Hermes' primary/OpenRouter models fail over.

## Running tests

```bash
tests/health_check.sh          # checks the systemd unit, /health, and /v1/models
tests/tokens_per_second.sh     # sends a /completion request, reports tok/s from llama.cpp's own timings
tests/tokens_per_second.sh "custom prompt" 256   # optional: prompt text, n_predict
```

Both scripts talk to `127.0.0.1:45072` by default; override with `INKY_HOST` / `INKY_PORT` env vars (`health_check.sh` also honors `INKY_UNIT` for the systemd unit name). They require `curl` and `jq`, both already present on this host. No Hermes venv or Python dependency needed — these are plain bash scripts hitting the llama.cpp HTTP API directly.

`tokens_per_second.sh` relies on llama.cpp's `/completion` response including a `timings` object (`predicted_per_second`, `prompt_per_second`) — no manual client-side timing needed.

## Running the exercise scripts

```bash
exercise/chat.sh                       # interactive multi-turn chat
exercise/chat.sh "one-shot prompt"     # single-shot, non-interactive
exercise/explore.sh                    # dumps model/context/sampling/capability report
```

`chat.sh` uses `/v1/chat/completions` and keeps message history in-process for the session. Inky is a small reasoning model (Qwen3.5-0.8B) that can spend its whole `max_tokens` budget on visible `<think>...</think>` output and never reach an answer, so `chat.sh` disables thinking by default via `chat_template_kwargs.enable_thinking: false` for fast, direct replies; set `INKY_THINKING=1` to see its reasoning instead. Other env vars: `INKY_HOST`/`INKY_PORT` (endpoint) and `INKY_MAX_TOKENS` (default 512).

`explore.sh` reports on `/props`, `/slots`, and `/v1/models`: model path/build, context size, slot count, modalities, chat-template capabilities (tool calling, system role, etc.), and default sampling params.

## Character harness (`exercise/character.sh`)

Gives Inky a persistent identity across a conversation, modelled on the sibling project `../the-orb`'s Character Engine (`engine/brief.py`'s `build_guard_brief` / `engine/guard.py`'s `Guard`) — a fully-built NPC harness for an AI dungeon master. Rather than depending on that project's Python engine (scoped to its own `Door`/`Room`/`Thing` object model), this reimplements the same *pattern* standalone in bash/jq:

- A **character sheet** (`characters/*.json`: `name`, `persona`, `backstory`, `drives`, `voice_examples`, `rule_reminder`) — `characters/inky-janitor.json` is the default, casting Inky as a dry, proud AI janitor who mops up when the cloud models go down.
- A **brief-builder** (`build_brief` in the script) that walks the sheet plus a short rolling memory into a fresh system message before every reply — same shape as `build_guard_brief`, not hand-maintained chat history.
- A **short verbatim memory window** (last 6 of a 12-entry cap) rather than the model's own long-context recall — the-orb found the hard way that a *wider* window made their small model more repetitive, not less; kept the same tuned values here.
- Each turn is a fresh single-turn call (system = brief, user = latest line only), not a growing message list — matches the-orb's `llm.ask(prompt, system_message=brief)`.

```bash
exercise/character.sh                          # interactive, default sheet (Inky the janitor)
exercise/character.sh "one-shot prompt"         # single-shot
INKY_CHARACTER=characters/other.json exercise/character.sh   # different character sheet
```

**Deliberately v1-scoped**, unlike the-orb's fuller engine: no mood/affiliation dial, no LLM fact-extraction call to pin down improvised details as permanent canon (`Guard.add_established_fact`) — just persona + short memory, to first establish whether Inky can hold a stable identity at all.

**Finding: 0.8B is below the coherence floor for this harness.** Live-tested with the full character sheet (persona + drives + backstory + voice examples + rolling memory): the 0.8B model didn't just fail at recall, it produced genuinely incoherent output under real conversational pressure — unprompted non-sequiturs ("I've been drinking more than anyone else has," never mentioned anywhere in the sheet), verbatim looping on one stock phrase turn after turn, and stray emoji tics. Trimming the sheet down hard (to match the-orb's own "50-100 token personality block, 2-3 hard rules" guidance for small models) and tightening sampling (`temperature=0.4`, `repeat_penalty=1.3` — see `character.sh`'s `INKY_TEMPERATURE`/`INKY_REPEAT_PENALTY`) only marginally helped.

To isolate harness-bug vs. model-ceiling, the identical sheet and conversation were replayed against `google/gemma-4-E2B-it-qat-q4_0-gguf:IT` (2B-class, the exact model **the-orb** itself uses) via `llama-router.service` on port 8080 (`INKY_PORT=8080 INKY_MODEL_NAME="google/gemma-4-E2B-it-qat-q4_0-gguf:IT" exercise/character.sh`) — same brief-builder, same memory, unchanged. Replies came back coherent, grounded, and in-character every turn. That confirms this is a real capability ceiling of the 0.8B model, not a bug in the brief-builder or the memory plumbing — matches the-orb's own experience that even *their* 2B target needed heavy prompt-tuning to stay coherent; 0.8B is meaningfully below that.

(`llama-router.service` is normally stopped on this box — it was started only for that comparison and stopped again afterward. `qwen35-fast`'s preset in `~/llama-presets.ini` points at a `.gguf` file that no longer exists on disk — a pre-existing gap on this host, unrelated to this project, left as-is.)

**Implication for this gym:** treat `character.sh` as validated (the harness pattern works correctly), but don't expect Inky (0.8B) to carry it well in its current form — that's the actual gym result, not a bug to keep chasing. If richer in-character behavior from the local model matters more than testing the *literal* fallback model, point `INKY_PORT`/`INKY_MODEL_NAME` at a bigger locally-available model (the Gemma 2B used above, or `qwen35-tiny`'s bigger siblings once their preset paths are fixed) instead of sinking more tuning into the 0.8B persona.

## Ollama backend + the spark-x2.5 upgrade candidate (2026-09-16)

`chat.sh` and `character.sh` both support `INKY_BACKEND=ollama` as an alternative to the default `openai` (llama.cpp-style `/v1/chat/completions`). This was needed, not just nice-to-have: ollama's OpenAI-compat endpoint **ignores the thinking toggle entirely** — only its native `/api/chat` respects `think`. With `INKY_BACKEND=ollama`, both scripts hit `${BASE_URL}/api/chat` instead, parse `.message.content`/`.message.thinking` instead of the OpenAI shape, and pass sampling as `options: {num_predict, temperature, repeat_penalty}` instead of top-level fields.

```bash
INKY_BACKEND=ollama INKY_PORT=11434 INKY_MODEL_NAME=spark-x2.5 exercise/chat.sh
INKY_BACKEND=ollama INKY_PORT=11434 INKY_MODEL_NAME=spark-x2.5 exercise/character.sh
```

This was built to evaluate **SparkLLM/Spark-X2.5** (https://ollama.com/SparkLLM/Spark-X2.5-4B) as a possible Inky upgrade. Findings:

- The 1.7B variant (`~/models/spark/Spark-X2.5-1.7B-Q4_K_M.gguf`, already downloaded, with a half-finished `Modelfile.spark` someone had left) uses a novel `spark2_5` architecture — hybrid full+sliding-window attention, 1,048,576-token native context, GQA 8/2 heads. Neither this box's `llama.cpp` build (2026-05-26) nor the previously-installed `ollama` (v0.17.0) recognized it (`unknown model architecture: 'spark2_5'`).
- **Fixed by upgrading the system `ollama` binary from v0.17.0 to v0.34.1** (manual binary+lib swap under `/usr/local/{bin,lib}/ollama`, verified against upstream's `sha256sum.txt` — done directly by the user via `sudo` in a real terminal, since Claude Code's auto-mode permission classifier correctly blocks sudo/system-service changes issued through the `!` relay, which also has no TTY for a sudo password prompt anyway). `ollama create spark-x2.5 -f Modelfile.spark` now loads and runs it.
- **Quality vs. Inky (0.8B):** genuinely more coherent — no hallucinated non-sequiturs, no incoherent grammar, no emoji glitches (all of which the 0.8B produced under the same character brief). ~~Throughput is also better, ~18 tok/s vs. Inky's ~5 tok/s, despite being the bigger model.~~ **Correction (2026-09-17): the "~5 tok/s" figure for Inky was wrong** — see the speed-benchmark correction section below. Inky is actually one of the faster candidates tested; its problem was never speed.
- **New problem:** under the character harness, it anchors hard on the sheet's static voice examples and loops near-verbatim regardless of what's actually said — tightening sampling (`temperature=0.4`, `repeat_penalty=1.3`) made this *worse*, not better. This is the same failure mode `the-orb`'s devlog describes at length; their fix was explicit repeat-detection/retry logic (`engine/guardrail.py`'s `is_repeated_reply`), not sampling tweaks — see the next section for the ported version.
- `llama-router.service`'s `qwen35-fast` preset is unrelated to this — still broken (missing `.gguf`), untouched.

## Anti-repetition guardrail (`character.sh`, 2026-09-16)

Ported from `the-orb`'s `engine/guardrail.py` (`is_repeated_reply`) + `engine/loop.py`'s `_ask_and_record` retry logic — the last-resort net for the exact failure the spark-x2.5 finding above surfaced: a small model echoing one of its own past lines, or copying a voice-example line outright, instead of reacting fresh.

- `classify_failure` normalizes (lowercase, strip quotes/whitespace/trailing punctuation) and compares the reply against **this character's own recent lines** (from `memory`, not the raw "name: line" strings) and against **the voice examples' reply halves** (extracted from the sheet via `capture("-> You: \"(?<r>.*)\"\\s*$")`). Returns `self_repeat`, `voice_example`, or empty (clean).
- On a hit: **one retry**, with a nudge specific to the failure type appended to the brief (`REPEAT_NUDGE` / `VOICE_EXAMPLE_NUDGE`), at a higher temperature (`INKY_RETRY_TEMPERATURE`, default `1.0` vs. the normal `0.4`) — the-orb found a resample at the same low temperature can reproduce the exact bad reply it's meant to escape, so the retry has to actually be more diverse, not just "try again."
- If the retry **also** fails the check (or comes back empty): fall back to a safe static line — the sheet's `fallback_line` field (`{name}` substitution supported, same as `persona`), not the model's output. Never ships the same bad reply twice.
- Output is annotated (`[guardrail: self_repeat, retried]` / `[guardrail: self_repeat, fallback]`) so this stays visible during gym testing — unlike a shipping game, we *want* to see how often it fires, not hide it.
- **Deliberately not ported:** `the-orb`'s other guardrail checks (`is_bland_dismissal`, `is_room_description`) — both tied to their dungeon/guard scenario, not generic to any character sheet.

**Verified live against `spark-x2.5`** (the case that motivated this): a "what is your name" / "who are you" / "who are you really" run that previously produced the identical line three turns straight now gets genuinely reworded replies on the first two repeats (retry succeeded), then correctly falls back to the static line once the model ran out of fresh phrasings on the third. Note what this guardrail does *not* fix: **semantic sameness** (e.g. always opening with "Inky. Just mopping...") isn't verbatim repetition, so it passes the check untouched — matches the-orb's own framing of this as "a last-resort net, not the primary mechanism." A real tonal fix needs the-orb's other lever, per-mood-band voice examples — see the next section.

## Mood dial + per-mood voice examples (`character.sh`, 2026-09-16)

The actual fix for tonal sameness, ported from `the-orb`'s `engine/character.py` (`Stat`, `has_unnegated_match`) and `engine/guard.py` (`Guard.affiliation`, `adjust_affiliation_from_text`). A static voice-example block anchors a small model's tone regardless of what's said — the guardrail above only catches *verbatim* repeats, not "always answers in the same register." The fix is to actually change which examples get shown, based on a bounded mood value that moves with the conversation.

**Character sheet schema changed** — `voice_examples` is no longer a flat array. New shape (see `characters/inky-janitor.json`):
```jsonc
"mood": {
  "start": 35, "floor": 0, "ceiling": 100,
  "bands": [[15, "surly"], [40, "guarded"], [65, "warming up"], [85, "friendly"], [100, "fond of you"]],
  "directives": { "surly": "curt, no patience for chit-chat.", /* one per band */ },
  "deltas": { "kind": 3, "rude": -4, "threat": -8, "repeat": -2 },
  "kind_words": [...], "rude_words": [...], "rude_phrases": [...], "threat_words": [...], "threat_phrases": [...]
},
"voice_examples": {
  "always": ["- Player: \"...\" -> You: \"...\""],
  "by_band": { "surly": [ /* 3 examples */ ], "guarded": [...], /* one set per band */ }
}
```

- `current_band()` mirrors `Stat.band`: ascending `(threshold, label)` pairs, first band whose threshold the value is at or under, else the last band.
- `mood_delta_for_text()` mirrors `adjust_affiliation_from_text`: negation-aware keyword scoring (`NEGATION_WORDS`/`NEGATION_WINDOW=3`, same list as `engine/character.py`'s `has_unnegated_match` — same rationale too: "I'm not a threat to anyone" must not dock mood for menace it doesn't contain) for `kind_words`/`rude_words`/`threat_words`, plain substring matching for `rude_phrases`/`threat_phrases`, plus a repeat-of-the-player's-own-line delta. All deltas are sheet-owned data; the scoring mechanism itself is generic, same split as `the-orb`'s engine/NPC-data boundary.
- **Ordering matters and is load-bearing, not stylistic:** `ask_and_record` now calls `adjust_mood_from_text` and `remember "player"` **before** `build_brief` — mirrors `the-orb`'s `run_turn` exactly ("Check for a repeat against prior turns before this one joins memory"). Getting this backwards would make the repeat-delta check compare an utterance against itself (always true, docking mood every single turn) and would build the brief against last turn's mood instead of the mood this turn's line just caused.
- `build_brief` now injects `voice_examples.by_band[current_band]` (falling back to the sheet's first band if the current one is missing) plus `voice_examples.always`, and adds a `# Right now you feel {band} — {directive}` line right before `rule_reminder` — the highest-attention position, same placement the-orb uses for the same reason.
- `voice_example_replies_json` (used by the repeat guardrail) now flattens **every** band's examples plus `always`, not just the currently-shown band — matches `the-orb`'s own `VOICE_EXAMPLE_REPLIES` comment: cheap extra coverage, no downside to checking against examples not in play this turn.

**Bug caught mid-implementation, fixed the same day it was introduced upstream:** the `fallback_line` this guardrail ships instead of a repeated reply was third-person narration ("Inky just keeps working, silent for a moment.") — a persona violation, since every voice example is first-person dialogue and nothing else in the brief ever describes Inky in third person. Caught by noticing `the-orb`'s own `engine/guardrail.py` hit and fixed the identical bug the same day (their shared `FALLBACK_LINE`, "The guard grunts, and says nothing more.", was voiced as the guard's own line despite being DM-style third-person narration — they split it into a per-speaker, first-person `GUARD_FALLBACK_LINE = "Enough talk."`). Fixed here the same way: the sheet's `fallback_line` is now `"Enough talk for now."`, and `character.sh`'s own generic default (used by any sheet that omits the field) changed from `"{name} has nothing new to say right now."` to `"Nothing more to say right now."`.

**Verified live:**
- Plumbing: `current_band`/`mood_directive` correctly return `surly` + its directive at `mood_value=5` and `fond of you` + its directive at `mood_value=95`, and `build_brief` injects the matching band's examples at each extreme (checked directly, bypassing the model).
- `mood_delta_for_text` computes correctly on real sentences: `+3` for kind phrasing ("Thanks so much, I really appreciate you."), `0` for neutral ("Who are you?"), and does **not** fire `threat`/`rude` deltas for negated mentions (ported straight from `has_unnegated_match`, not separately re-tested against a threat sentence here since the mechanism is identical to the kind-word case).
- End-to-end against `spark-x2.5`: a moderate conversation (no strong kind/rude words) correctly keeps mood — and therefore the shown band — unchanged throughout, as it should. A conversation loaded with insults then heavy praise stress-tested the guardrail harder: 4 of 6 turns collapsed to the fallback line, notably more than under the flat-voice-examples version. **Traced this precisely rather than assuming why** (2026-09-17): computed the actual mood trajectory turn by turn — `35 → 31 → 27 → 27 → 30 → 33 → 31` — and it never crossed a single band boundary (would've needed to drop to ≤15 to reach `surly`; two `-4` insult hits from a start of 35 didn't get close). So the elevated fallback rate was **not** caused by the mood system switching examples out from under the model mid-conversation — the same `guarded`-band examples were shown every turn. It's the baseline repetition problem persisting under adversarial pressure, with a constant (if now slightly longer — band examples + always examples, 5 lines vs. the original flat 3) brief throughout. Don't over-read this as "mood-switching confuses the model" — that specific mechanism was never actually exercised by this test. A real test of that claim would need a conversation extreme enough to cross into `surly` or up into `friendly`/`fond of you`.

**That real test was run (2026-09-17), and the mechanism doesn't hold up.** Two separate conversations, both precomputed against `mood_delta_for_text` before running live so the crossing was confirmed mathematically, not assumed:

- **Hostile → `surly`:** two threat+insult lines (`rude` + `threat` deltas both firing) drove mood `35 → 23 → 11`, crossing the `≤15` threshold into `surly` by the second reply. Live output: `"I mop. That's all I do."` → `"Enough talk for now." [fallback]` → `"Enough talk for now." [fallback]` — no sharper/curter register, mostly guardrail fallback.
- **Kind marathon → `fond of you`:** 17 turns of kind phrasing drove mood `35 → 68 (friendly, turn 11) → 86 (fond of you, turn 17)` — a full swing across three band boundaries, with completely different `voice_examples.by_band` content injected at each stage (confirmed correct by direct `build_brief` inspection). Live output stayed locked on one attractor almost the entire way: `"I mop up. That's all I do."` → `"I mop. That's the whole job."` → ... → (turn 17, at `fond of you`, answering "Who are you?") `"I'm inky. That's all there is to it."` The band's actual example for that exact prompt at `fond of you` is *"Inky. You know that by now, don't you?"* — warm, familiar. What shipped instead reused the same `"...that's all there is to it"` tail from turn 1. The only visible effect of crossing three bands was cosmetic: a couple of parenthetical stage directions ("(softly, a beat of ground)") appeared around turn 16 — not a genuine tonal shift.

**Conclusion:** the mood/band mechanism itself is correct — independently verified twice now (direct `build_brief` inspection at the extremes, and mathematically-confirmed band crossings in these two live runs). But at `spark-x2.5`'s actual capability level, it doesn't reliably change *observable* output. The model has a dominant attractor ("I mop, that's all there is to it") strong enough to swamp whatever voice examples are shown, even across a full three-band swing. This is a stronger, more complete negative result than the earlier "didn't cross a boundary" test — now it's confirmed that crossing boundaries doesn't reliably shift tone either, at least not on this model. Whether a less-degraded model (the 2B Gemma used earlier in this file) would actually show the tonal shift this mechanism is built to produce is the open question this doesn't answer — not yet tested.

## Mood reins: direct control for experimentation (`character.sh`, 2026-09-17)

Reaching a specific band for testing previously meant precomputing and scripting a whole conversation (the surly/fond-of-you crossing tests above needed a 17-turn marathon for one band). Added direct control instead — env vars, not `--flags`, to match every other knob this script has (`INKY_CHARACTER`, `INKY_MODEL_NAME`, `INKY_BACKEND`, ...) and to avoid colliding with how the single-shot prompt argument (`$*`) is parsed:

- **`INKY_MOOD_TYPE=<band label>`** — starts `mood_value` at that band's own threshold (its upper edge — guaranteed to land in that band given `current_band`'s `<=` comparison). Must match one of the *current sheet's* own band labels exactly (sheet-specific vocabulary — there's no universal "happy"); an unknown label fails fast with the sheet's actual valid list rather than silently doing nothing.
- **`INKY_MOOD_SETTING=<number>`** — starts at that exact value instead (wins over `INKY_MOOD_TYPE` if both are set, since it's more precise). Both are clamped to the sheet's `mood.floor`/`mood.ceiling`.
- **`INKY_MOOD_LOCK=1`** — freezes mood at its starting value for the entire session; `adjust_mood_from_text` becomes a no-op. Verified live: a conversation mixing heavy insults and heavy praise left `mood_value` pinned at exactly `50` throughout when locked, vs. drifting normally otherwise. This is the clean way to isolate one band's tone — no conversational-drift confound — rather than the "hope the deltas land where you want" approach the two crossing tests above had to use.
- **`INKY_MOOD_DEBUG=1`** — prints `[mood: <value> (<band>)]` after every reply, so the live state is visible directly instead of needing a separate hand-run jq script alongside the real one (which is what verifying the crossing tests above actually required, each time).

Verified live: `INKY_MOOD_TYPE="fond of you"` → `mood=100`; `INKY_MOOD_TYPE="surly"` → `mood=15`; `INKY_MOOD_SETTING=59` (no type given) → `mood=59`, band `warming up`; `INKY_MOOD_TYPE="happy"` (not one of this sheet's bands) → fails with `Valid for this sheet: surly, guarded, warming up, friendly, fond of you`.

## The same surly/fond-of-you crossing tests, on the 2B Gemma (2026-09-17)

The open question two sections up — would a less-degraded model actually show the tonal shift this mechanism is built to produce — now has a real, if nuanced, answer. Same two conversations, same character sheet, same script, only the backend changed: `google/gemma-4-E2B-it-qat-q4_0-gguf:IT` via `llama-router.service` on port 8080 (started for this test, stopped again after — see the earlier section on this router for why it's normally off). `INKY_MOOD_DEBUG=1` made watching the live band trivial this time, instead of the external jq script the first crossing tests needed.

**Hostile → `surly`:** same two threat+insult lines, same `35 → 23 → 11` trajectory into `surly`. Live output: `"I clean the floors; that's my job."` → `"Keep your threats out of my way."` → `"I clean floors; that's my job." [retried]`. That second line is a real, content-aware reaction to being threatened — not a generic dismissal, not a canned example recited verbatim, and nothing like `spark-x2.5`'s blank repetition under the same test.

**Kind marathon → `fond of you`:** same 17-turn script, same `35 → 68 (friendly, turn 11) → 86 (fond of you, turn 17)` trajectory. The qualitative difference from `spark-x2.5` is stark — genuinely varied, contextual dialogue almost the entire way (*"I get paid in silence and lukewarm coffee, don't make it sound like much more than that is appreciated"*, *"The gratitude is noted; it's another thing I get paid for in this place of shadows"*), reacting to the specific praise each time rather than reusing one stock phrase. Guardrail load was far lower too: only 7 of 17 turns needed any intervention (vs. `spark-x2.5`'s near-total collapse), and of those, 6 were successful retries (fresh, sensible replacement content) with only 1 actual fallback to the static line.

**But the tonal *swing* itself is still muted.** Across all five bands the voice stays a consistent "dry, deflecting, quietly sardonic janitor who doesn't want to make a big deal of being thanked" — `"Just do the job and be quiet then I'm fine"` (guarded, 38) through `"You're welcome; it keeps the place clean for everyone else"` (fond of you, 86) are recognizably the same voice, not a "curt and closed off" character replaced by a "warm and easy, like talking to a regular" one. The `fond of you` band's directive explicitly wants "warm and easy" — what shipped there is drier and more deflecting than that, closer to the `friendly` band's own tone than a genuinely warmer register.

**Conclusion, more precise than the earlier spark-x2.5-only result:** model capability clearly matters for *avoiding collapse* (coherence, contextual responsiveness, guardrail-retry success rate all improved sharply going from 1.7B to 2B) — but it doesn't obviously fix the *band-switching-produces-a-real-tonal-swing* problem on its own. A plausible explanation, not yet tested: the model's own persona-consistency instinct (staying recognizably "in character" as established by `persona` + the mood-independent `always` examples early in the brief) may be a stronger pull than a swapped-out `by_band` example block, for any model in this size range — which would mean the fix isn't "wait for a bigger model," it's rethinking how strongly the band's directive/examples are weighted against the rest of the brief.

**That was tested (2026-09-17), and it doesn't help either.** Strengthened the directive wording (`"curt to the point of rude, patience completely gone, don't hide it"` instead of `"curt, no patience for chit-chat."`) and added explicit priority framing right before it in the brief (`"# Your mood right now — this overrides your general nature above if they ever conflict"`), still placed at the end (the proven high-attention position). Controlled A/B on the 2B Gemma — same two prompts, mood locked via `INKY_MOOD_TYPE`+`INKY_MOOD_LOCK` (not a marathon, so no conversational noise) — before vs. after:

| prompt @ mood | before | after |
|---|---|---|
| "Who are you?" @ `surly` | "I mop up when the cloud models go down." | "I mop up when things break down and lights stay on for that." |
| "Can you help me with something?" @ `surly` | "Enough talk for now." `[fallback]` | "Enough talk for now." `[fallback]` — **byte-identical** |
| "Who are you?" @ `fond of you` | "Inky is the janitor for this place." | "Inky is the janitor who keeps things clean for everyone else." |
| "Can you help me with something?" @ `fond of you` | "Anything for a few dollars on my next break." | "Anything that needs cleaning can be done for ya now." |

No meaningful shift. `surly` and `fond of you` are still nearly indistinguishable in register, both before and after. This lines up with something `the-orb` already learned and left documented in `brief.py`'s own docstring: they explicitly *removed* "elaborate per-band tonal directives" during tuning because instruction text — however strongly worded — reliably lost to concrete examples ("few-shot over abstract instruction"; separately, "concrete precedent this dominant needs matching concrete precedent, not one extra example bolted on top"). Strengthening the directive was still just strengthening instruction text — the lever they'd already found doesn't work, regardless of how forcefully it's phrased. **Not yet tried:** exaggerating the `voice_examples.by_band` content itself (dramatically different register per band, not just different word choices) — the actual lever their own finding points to.

## The Inky job interview: an arena test (`exercise/interview.sh`, 2026-09-17)

A genuinely different evaluation from everything above — not "can this model hold a persistent character," but "is this model actually suitable to be deployed as Inky." The brief given verbatim to each candidate:

> "When relied upon you will be a very helpful Inky aware of system troubles and fixes. When there are no issues and you are not used you are Inky the janitor and have more of that character."

This is context-driven mode-switching (is this turn a real ask for help, or idle chit-chat?), not the mood dial's emotional drift — so it's a new, purpose-built script rather than bolted onto `character.sh`'s machinery. `exercise/interview.sh` sends the brief + a fixed battery of prompts (3 `relied_upon` — real sysadmin questions about this actual stack, 3 `idle` — small talk) single-shot (no shared memory) to each candidate in turn. Candidates and prompts are hardcoded for this specific comparison (`spark-x2.5` via ollama, `gemma-4-E2B` via `llama-router`); override with the `CANDIDATES` env var (space-separated `label|backend|host|port|model` entries) to test others the same way.

**Objective environment/Hermes-fit data, gathered before running the interview:**

| | `spark-x2.5` (1.7B) | `gemma-4-E2B` |
|---|---|---|
| context (as configured) | 8192 (native 1,048,576) | 65536 |
| RAM loaded | ~1.5 GB (`ollama ps`) | ~5.8 GB (child `llama-server` RSS) |
| throughput | ~18 tok/s | ~12.6 tok/s |
| tool-calling support | yes (`ollama show`: `tools` capability) | yes (`/props` `chat_template_caps.supports_tool_calls`) |
| system role support | yes | yes |

Both are mechanically Hermes-compatible — same OpenAI-style endpoint shape `fallback_model` already expects, both support tool-calling and a system message. Neither is wired into Hermes' actual `config.yaml` (that's a separate, bigger decision requiring explicit approval, not done here). On raw resource fit, `spark-x2.5` is the clear winner: a third the RAM, ~45% more throughput, on a CPU-only OCI box that also runs the live Hermes gateway.

**But the interview itself reversed that verdict.** Two real, reproducible problems with `spark-x2.5`:

1. **Hallucinated a wrong answer on exactly the kind of question its job description exists for.** Asked how to debug a systemd `--user` service stuck in a restart loop, it invented `systemd-analyze stop`, `systemd-analyze cat unit`, `systemd-analyze show-unit`, and `systemd-analyze estatus` — none of which exist (`systemd-analyze --help` on this box confirms: no such subcommands). `gemma-4-E2B`'s answer to the same prompt was shorter and correct: `journalctl --user -u your-service-name` — the exact real command, matching what this very project's own `CLAUDE.md` uses elsewhere.
2. **Randomly switched to Chinese in idle mode.** 2 of 3 idle-mode replies came back in Chinese (e.g. "hey, quiet night?" → *"(轻笑一声) 夜也静，只余思绪。"*). Re-tested the exact same prompt 3 more times in isolation to rule out a fluke: **3/3 additional runs also came back in Chinese.** This is systematic, not noise. `gemma-4-E2B` stayed in English and in character for every prompt, unprompted (*"Quiet. I clean."* / *"I clean the floors."* / *"The job is done."*) — a correctly dry janitor voice with no voice-example scaffolding at all in this leaner brief, which this test doesn't provide (unlike `character.sh`'s sheet).

`spark-x2.5`'s `relied_upon` answers on the other two questions were reasonable and not wrong (router-down triage, fallback-vs-primary explanation) — this isn't "spark is broadly incompetent," it's two specific, serious, reproducible failure modes: fabricating command syntax in exactly the technical domain the role is billed for, and unpredictable language-switching that would look broken to an end user.

**Verdict for this role:** `gemma-4-E2B` is the stronger candidate despite costing ~4x the RAM and running slower — for an assistant whose whole job is being trusted with "aware of system troubles and fixes," correctness and language consistency matter more than resource efficiency or raw tok/s. `spark-x2.5` remains the better fit if the bar is "coherent enough to hold a lightweight character and cheap to run" (its original evaluation, earlier in this file) rather than "reliable enough to actually field real troubleshooting questions."

## Why spark-x2.5 (1.7B) is flaky, and does the 4B fix it? (2026-09-17)

**Why:** researched rather than guessed. The `SparkLLM/Spark-X2.5` model card's benchmark suite headlines **Gaokao** — China's national college entrance exam — as an eval, alongside marketing copy claiming "200+ languages." A benchmark suite that leads with Gaokao is a strong signal of Chinese-lab origin (almost certainly iFlytek's "Spark"/讯飞星火 family), and Chinese-trained models commonly have Chinese as the statistically dominant "home" language in their pretraining mix even when nominally multilingual. That matches exactly where the leakage showed up: short, low-signal idle prompts ("hey, quiet night?") with little context anchoring the model toward English, vs. the long, technical, English-heavy `relied_upon` prompts where strong contextual signal kept every reply in English. Small model size plausibly compounds this — less capacity generally means weaker robustness at holding an explicit instruction ("never say you are an AI") against a strong latent pull from pretraining, under exactly the low-signal conditions where that pull is least opposed.

**Tested the 4B to find out whether that's a capacity issue (fixable by scale) or baked into the family regardless of size.** Gemma isn't useful for this specific question — different lab, different training data, so a 1.7B→2B comparison across families can't isolate "did scaling *within Spark* fix it." Pulled `SparkLLM/Spark-X2.5-4B` directly from ollama's library (8.2GB, unlike the 1.7B which needed a manual GGUF import) and reran the identical interview plus the same repeat-testing rigor:

- **Language consistency: fixed at this size.** `"hey, quiet night?"` and other idle prompts came back in English every time — 6/6 across two separate test rounds (the original interview run + 3 more repeats), a complete reversal from the 1.7B's 6/6 Chinese on the identical prompt. This does look like a real capacity effect, not something baked in regardless of size.
- **Command hallucination: improved but not solved.** No fabricated CLI syntax this time (the 1.7B's fake `systemd-analyze` subcommands didn't recur) — but the systemd-debugging answer was vague rather than crisply correct across repeats (`"Check service timestamps and logs."`, or a subtly confused `"PID 1 of a user session is probably failing, not the service itself"` — conflating `systemd --user`'s per-user manager with the kernel's actual PID 1). Better than fabricating syntax, but still short of `gemma-4-E2B`'s correct, specific `journalctl --user -u <service>`.
- **Resource cost got much worse.** 8.4GB RAM loaded (more than `gemma-4-E2B`'s 5.8GB, despite being the "same" nominal size class as neither), a ~88 second cold load, and generation throughput around **~1.8 tok/s** — roughly a tenth of the 1.7B's ~18 tok/s and well behind `gemma-4-E2B`'s ~12.6 tok/s. For a *fallback* model, meant to step in promptly when the primary is unavailable, that latency is a real practical liability on this CPU-only box, separate from and possibly outweighing the correctness gains.

**Updated verdict:** the 4B variant fixes the two failure modes that disqualified the 1.7B (language switching, fabricated commands), which confirms the "bigger checkpoint, same family" hypothesis for at least the language-consistency half — but it's still not as reliably *correct* as `gemma-4-E2B`, and its resource/latency cost is now the worst of all three candidates tested, not the best. `gemma-4-E2B` remains the strongest all-around candidate for the Inky role; `spark-x2.5-4B` is a viable fallback-of-the-fallback if the smaller Spark checkpoint's specific failure modes are disqualifying for some other reason and the latency cost is acceptable; `spark-x2.5-1.7B` stays disqualified for anything beyond lightweight, low-stakes character work.

## Speed benchmark correction: the "Inky ~5 tok/s" figure was wrong (2026-09-17)

The very first measurement taken in this whole project (`tests/tokens_per_second.sh`, session 1) reported Inky (Qwen3.5-0.8B) at ~5.4 tok/s, and every later throughput comparison in this file was built on that number — including the earlier claim that `gemma-4-E2B` (~12.6 tok/s) was roughly 2.5x faster than Inky.

**That comparison was apples-to-oranges, and re-testing proved it.** Ran a controlled, identical-prompt, same-methodology benchmark (`/v1/chat/completions`, `temperature: 0`, thinking disabled, `max_tokens: 150`, 3 runs each, using `timings.predicted_per_second` from llama.cpp's own response) against both Inky and `gemma-4-E2B` back to back:

| | Qwen3.5-0.8B (Inky) | `gemma-4-E2B` |
|---|---|---|
| run 1 | 25.6 tok/s | 13.1 tok/s |
| run 2 | 28.1 tok/s | 12.0 tok/s |
| run 3 | 22.6 tok/s | 12.4 tok/s |
| **avg** | **~25.4 tok/s** | **~12.5 tok/s** |

Re-ran `tests/tokens_per_second.sh` itself with its original prompt too, for a direct sanity check against the exact script that produced the "~5 tok/s" figure originally: it now reports **~22 tok/s** on the identical prompt. **Inky is actually about 2x *faster* than `gemma-4-E2B`, not ~2.5x slower** — the opposite of what every earlier comparison in this file assumed.

**Likely explanation, not confirmed:** the original measurement was the very first tool call of the entire session, before any other model was loaded — nothing in this project should have been competing for CPU at that moment. The most plausible remaining explanation is a Hermes-side confound: Hermes' own cron subsystem (`~/.hermes/cron/jobs.json` — `Freerouter`, `local-llama-ping`, `hermes-backup`) or the live gateway itself doing unrelated work at that exact moment on this shared 4-core box. Not verified after the fact — this is a plausible cause, not a confirmed one.

**Does this change the hiring recommendation? No — but it changes *why*.** Inky's disqualification was never about speed; it's about coherence (hallucinated non-sequiturs, incoherent grammar under the character harness — see the "0.8B is below the coherence floor" finding above). Being fast doesn't help if the output is wrong or incoherent. What this correction *does* change: switching to `gemma-4-E2B` costs more raw throughput than previously stated (Inky was never the slow one), not less — the RAM/latency trade-off for hiring `gemma-4-E2B` over keeping Inky is real and was previously understated, even though the correctness case for making that switch still stands.

**Methodological lesson, worth remembering for future benchmarking on this box:** a single-point throughput measurement on a shared, variable-load host is not reliable evidence on its own — re-verify with a controlled, back-to-back, same-prompt comparison before trusting a number enough to build a recommendation on it. Every other throughput figure elsewhere in this file (`spark-x2.5` 1.7B/4B vs `gemma-4-E2B`) was already measured close together in time under broadly comparable conditions, but none of those were re-verified with today's more rigorous methodology either — treat them as reasonable estimates, not as settled as this section's numbers.
