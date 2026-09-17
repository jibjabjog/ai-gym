# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose (from README.md)

A gym for testing "Inky the janitor AI" — Inky is a stand-in name for any AI under test, defaulting to the local Hermes failover called "Inky". Two planned areas:

- **Tests** (`tests/`): scripts to verify Inky is running OK and measure tokens/second.
- **Exercise** (`exercise/`): scripts to exercise Inky — a simple chat-starter script, a script to explore Inky's capabilities and specification, and a character-harness script that gives Inky a persistent persona.

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
- **Quality vs. Inky (0.8B):** genuinely more coherent — no hallucinated non-sequiturs, no incoherent grammar, no emoji glitches (all of which the 0.8B produced under the same character brief). Throughput is also better, ~18 tok/s vs. Inky's ~5 tok/s, despite being the bigger model.
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
