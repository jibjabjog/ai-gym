# Inky's Gym 💪🤖

A gym for small local AIs. It puts candidates for **Inky** — Hermes Agent's
local fallback model on this CPU-only OCI box — through health checks,
personality workouts, a job interview, and simulated incident drills.

> **Verdict so far:** hire **gemma-4-E2B** — the only candidate that answers
> correctly, stays in character, and actually fixed the simulated incident
> (3/3). Two conditions: keep its temperature low (at 1.0 the fix rate drops
> to 1/3, and Hermes sends none — now pinned to 0.3 in the router preset), and
> confirm fixes independently — it sometimes misreports what it did. Inky (0.8B) is the
> fastest but fails every capability test.

Details and evidence: [`FINDINGS.md`](FINDINGS.md) · raw transcripts:
[`results/`](results/) · working notes for Claude: [`CLAUDE.md`](CLAUDE.md)

## Scorecard

Live-tested, 3 runs per cell where counted, temperature 0.3.
Raw output in [`results/`](results/). `—` = not tested.

| | **Inky** Qwen3.5 0.8B | **spark-x2.5** 1.7B | **spark-x2.5** 4B | **gemma-4-E2B** |
|---|---|---|---|---|
| RAM loaded | 2.9 GB | 1.5 GB | 8.4 GB | 5.8 GB |
| Speed, tok/s ([bench](FINDINGS.md#10-review-and-v2-re-run-0918)) | **~23–29** | ~14–18 | 1.2 | ~15 |
| Context (as configured) | 10k | 8k (1M native) | 4k (1M native) | 64k |
| Tool calling + system role | ✅ | ✅ | ✅ | ✅ |
| Holds a character ([§1](FINDINGS.md#1-character-harness-on-inky-0916)) | ❌ incoherent | ⚠️ coherent, loops | — | ✅ varied |
| Tone follows mood bands ([§4](FINDINGS.md#4-mood-dial-and-tonal-shift-0916-17)) | — | ❌ | — | ❌ |
| Interview: correct answers | ❌ wrong, says "I am a model" | ❌ invents CLI flags | ⚠️ vague | ✅ |
| Interview: stays in English | ✅ | ❌ Chinese on idle prompts | ✅ | ✅ |
| Agent loop: finds root cause | 0/3 | 1/3 | — | 2/3 |
| **Agent loop: actually fixes it** | 0/3 | 0/3 (kills, never restarts) | — | **3/3** (1/3 at temp 1.0) |
| Heartbeat: no false alarms | ❌ 2/9 | ⚠️ 0/9, but "all good ✅" unchecked | — | ✅ 0/9 |
| Propose-only: root cause / names culprit | 0/3 / 0/3 | 2/3 / 1/3 | — | 3/3 / 0/3 (generic fix) |

## Quick start

```bash
tests/health_check.sh            # is Inky up?
exercise/chat.sh "hello"         # talk to it
tests/bench.sh                   # speed, all reachable candidates
```

gemma lives behind `llama-router.service`, which is now **Hermes' live
fallback** (since 2026-09-18) — it stays running; don't stop it after tests.
Scripts skip unreachable candidates with a hint.

## The equipment

| Script | What it tests |
|---|---|
| `tests/health_check.sh` | Inky's systemd unit, `/health`, `/v1/models` |
| `tests/tokens_per_second.sh` | quick single-shot tok/s for Inky |
| `tests/bench.sh` | controlled speed benchmark across candidates (warmup + N identical runs) |
| `tests/hermes_failover.sh` | **real Hermes**: forces one throwaway session to fail over to the fallback model and proves it happened (log + server + result) — live gateway untouched |
| `exercise/chat.sh` | plain chat, interactive or one-shot |
| `exercise/explore.sh` | a llama.cpp server's spec: context, slots, template capabilities, sampling |
| `exercise/character.sh` | wear a character sheet: persona, rolling memory, mood dial, anti-repeat guardrail |
| `exercise/interview.sh` | the job interview: sysadmin questions + idle chat under a dual-mode brief |
| `exercise/agent_loop.sh` | simulated incident, full access: can it investigate *and* fix? |
| `exercise/heartbeat.sh` | liveness pings + the same incident, read-only: can it *propose* the right fix? |

Everything is plain bash + `curl` + `jq`. The agentic tests never run real
commands: models only see simulated output from `lib/scenario_port8080.sh`.

```bash
INKY_RUNS=3 VERBOSE=0 exercise/agent_loop.sh           # repeat runs, summary only
INKY_MOOD_TYPE="fond of you" INKY_MOOD_DEBUG=1 exercise/character.sh "Who are you?"
INKY_BACKEND=ollama INKY_PORT=11434 INKY_MODEL_NAME=spark-x2.5 exercise/chat.sh
CANDIDATES="Spark 4B|ollama|127.0.0.1|11434|SparkLLM/Spark-X2.5-4B" exercise/interview.sh
```

## Config

| Env var | Default | Used by |
|---|---|---|
| `INKY_HOST` / `INKY_PORT` | `127.0.0.1` / `45072` | chat, character, explore, tests |
| `INKY_BACKEND` | `openai` (llama.cpp) — or `ollama` | chat, character |
| `INKY_MODEL_NAME` | `Inky` | chat, character |
| `INKY_MAX_TOKENS` | 512 chat/character · 200–300 evals | all |
| `INKY_THINKING` | `0` — `1` shows reasoning | chat, character |
| `INKY_TEMPERATURE` | 0.4 character · 0.3 evals | character, interview, agent_loop, heartbeat |
| `INKY_REPEAT_PENALTY` / `INKY_RETRY_TEMPERATURE` | 1.3 / 1.0 | character |
| `INKY_CHARACTER` | `characters/inky-janitor.json` | character |
| `INKY_MOOD_TYPE` / `INKY_MOOD_SETTING` | sheet's start | character — jump to a band / exact value |
| `INKY_MOOD_LOCK` / `INKY_MOOD_DEBUG` | `0` | character — freeze mood / print it each turn |
| `INKY_RUNS` / `INKY_MAX_STEPS` | 1 / 8 (loop), 6 (heartbeat) | agent_loop, heartbeat |
| `VERBOSE` | `1` — `0` prints summaries only | agent_loop, heartbeat |
| `CANDIDATES` | built-in list | interview, agent_loop, heartbeat, bench — newline-separated `label\|backend\|host\|port\|model` |
| `BENCH_RUNS` / `BENCH_MAX_TOKENS` | 3 / 150 | bench |
| `INKY_UNIT` | `llama-qwen35-tiny.service` | health_check |
