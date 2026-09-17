# Inky's Gym 💪🤖

A gym for AIs. Right now it's a place to put **Inky** — the local Hermes
failover model — through its paces, but "Inky" is really just a stand-in
name: point these scripts at any OpenAI-compatible endpoint and they'll spot
for whatever AI you're training.

Inky itself is the `llama-qwen35-tiny.service` systemd unit: a `llama.cpp`
server running `Qwen3.5-0.8B-Q4_K_M.gguf` on `127.0.0.1:45072`, serving as
Hermes Agent's local fallback model when the primary/OpenRouter models are
unavailable.

## The equipment

### 🩺 `tests/` — health checks

Make sure Inky showed up and is actually lifting today.

```bash
tests/health_check.sh                # systemd unit + /health + /v1/models
tests/tokens_per_second.sh           # throughput, in tok/s
tests/tokens_per_second.sh "custom prompt" 256
```

### 🏋️ `exercise/` — workouts

Put Inky through some reps.

```bash
exercise/chat.sh                     # interactive multi-turn chat
exercise/chat.sh "one-shot prompt"   # single-shot, non-interactive
exercise/explore.sh                  # spec sheet: context size, slots, sampling, capabilities
```

Inky is a small reasoning model and can spend its entire token budget
thinking out loud instead of answering, so `chat.sh` keeps its `<think>`
tags switched off by default — set `INKY_THINKING=1` to watch it sweat.

### 🎭 `characters/` + `exercise/character.sh` — give it a personality

Inky doesn't just chat, it can wear a character. `characters/inky-janitor.json`
casts it as a dry, world-weary AI janitor who mops up whenever the fancy
cloud models go down — persona, backstory, drives, and a few voice examples,
all rebuilt into a fresh brief before every reply, plus a short rolling
memory of the conversation so far.

```bash
exercise/character.sh                        # chat with Inky the janitor
exercise/character.sh "one-shot prompt"       # single-shot
INKY_CHARACTER=characters/other.json exercise/character.sh   # a different character sheet
```

The pattern is borrowed from `../the-orb` (a sibling project building an
audio D&D engine with a much fuller NPC harness) — same idea of a
brief-builder walking character state into the system prompt each turn,
reimplemented here in plain bash/jq to match this gym's no-dependencies
style.

**Gym result, not a bug:** at 0.8B, Inky is genuinely too small to carry this
well — under real conversational pressure it drifted into unprompted
non-sequiturs and looping stock phrases, not just shaky memory. Swapping in
a bigger local model (`the-orb`'s own 2B Gemma, same brief, same script)
came back coherent every turn, which confirms the harness itself works —
0.8B is just below the floor for holding a character. See `CLAUDE.md` for
the full comparison. Want a richer character exercise? Point `character.sh`
at a bigger model instead of fighting the 0.8B persona further:

```bash
INKY_PORT=8080 INKY_MODEL_NAME="google/gemma-4-E2B-it-qat-q4_0-gguf:IT" exercise/character.sh
# requires: systemctl --user start llama-router.service (not running by default)
```

### 🆕 Trying an upgrade candidate: `spark-x2.5` via ollama

Both `chat.sh` and `character.sh` can talk to ollama instead of a llama.cpp
server — set `INKY_BACKEND=ollama` (ollama's OpenAI-compat endpoint doesn't
support the thinking toggle, so this switches to its native `/api/chat`):

```bash
INKY_BACKEND=ollama INKY_PORT=11434 INKY_MODEL_NAME=spark-x2.5 exercise/chat.sh
INKY_BACKEND=ollama INKY_PORT=11434 INKY_MODEL_NAME=spark-x2.5 exercise/character.sh
```

`spark-x2.5` (1.7B, [SparkLLM/Spark-X2.5](https://ollama.com/SparkLLM/Spark-X2.5-4B))
was evaluated as a possible Inky upgrade — noticeably more coherent than the
0.8B and faster, but it anchors hard on the character sheet's voice examples
and loops near-verbatim across turns. `character.sh` now catches this: a
guardrail (ported from `the-orb`'s `guardrail.py`/`loop.py`) detects a
near-verbatim echo of the character's own past line or a voice example,
retries once at a higher temperature, and falls back to a safe static line
if the retry also fails — annotated in the output as
`[guardrail: self_repeat, retried]` / `[guardrail: self_repeat, fallback]`
so it stays visible during testing.

That guardrail fixes verbatim looping, not tonal sameness (always opening
the same way) — for that, `character.sh` now has a **mood dial**, also
ported from `the-orb` (`Stat` + `Guard.affiliation`). Character sheets
define mood bands (e.g. `surly` → `guarded` → `warming up` → `friendly` →
`fond of you`), each with its own set of voice examples and a short
directive; kind/rude/threatening words in what you say (negation-aware —
"I'm not a threat" won't dock it) nudge a bounded mood value up or down,
which picks which band's examples actually get shown each turn. See
`characters/inky-janitor.json` for the schema and `CLAUDE.md` for the full
writeup — including a bug this caught (a fallback line that broke character
by narrating in third person, the exact bug `the-orb` fixed in its own
guardrail the same day) and an honest negative result: two conversations
built to deliberately cross into `surly` and `fond of you` (band crossings
confirmed by precomputing the mood math before running) showed the
mechanism itself works correctly, but `spark-x2.5` barely changes its
observable tone across a full three-band swing — it has a dominant
"I mop, that's all there is to it" attractor strong enough to swamp
whichever voice examples are actually shown.

Experimenting with a specific mood is now instant instead of needing a
scripted multi-turn conversation to drift there:

```bash
INKY_MOOD_TYPE="fond of you" INKY_MOOD_DEBUG=1 exercise/character.sh "Who are you?"
INKY_MOOD_SETTING=10 INKY_MOOD_LOCK=1 exercise/character.sh   # pin mood, no drift, clean A/B testing
```

## Config

All scripts talk to `127.0.0.1:45072` (Inky) by default. Override with:

- `INKY_HOST` / `INKY_PORT` — where the model lives
- `INKY_UNIT` — systemd unit name (`health_check.sh` only)
- `INKY_MAX_TOKENS` — reply length cap (`chat.sh`/`character.sh`, default 512)
- `INKY_THINKING` — set to `1` to show reasoning output (`chat.sh`/`character.sh`)
- `INKY_CHARACTER` — path to a character sheet (`character.sh` only, default `characters/inky-janitor.json`)
- `INKY_MODEL_NAME` — the `model` field sent in the request (`chat.sh`/`character.sh`, default `Inky`) — set this to test against a different model on `INKY_PORT`
- `INKY_TEMPERATURE` / `INKY_REPEAT_PENALTY` — sampling for `character.sh` (default `0.4` / `1.3`, tightened from the server's defaults to keep small-model replies grounded rather than rambling)
- `INKY_BACKEND` — `openai` (default, llama.cpp-style `/v1/chat/completions`) or `ollama` (`/api/chat`, needed for ollama's `think` toggle to actually work)
- `INKY_MOOD_TYPE` — start at a named band's threshold value instead of the sheet's default (`character.sh` only; must match one of the sheet's own band labels, e.g. `surly`/`guarded`/`warming up`/`friendly`/`fond of you` for the janitor sheet — errors out and lists valid options otherwise)
- `INKY_MOOD_SETTING` — start at this exact numeric mood value instead (wins over `INKY_MOOD_TYPE` if both are set)
- `INKY_MOOD_LOCK` — set to `1` to freeze mood at its starting value for the whole session (no drift from what's said — useful for isolating one band's tone cleanly)
- `INKY_MOOD_DEBUG` — set to `1` to print the live mood value + band after every reply

Requires `curl` and `jq`. No Python, no Hermes venv — just plain bash
talking straight to the llama.cpp HTTP API.
