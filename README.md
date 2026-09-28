# Inky's Gym 💪🤖

A workout room for putting an AI model through its paces **for a specific role** —
health checks, a job interview, throughput benchmarks, and scored, repeatable
incident drills. The gym is deliberately role-agnostic: it's an exam / interview /
testing ground for *any* purposed AI reachable over an HTTP chat endpoint. Its first
and current tenant is **Inky** — the local fallback model on this CPU-only OCI box
that stands in when Hermes' cloud models are unreachable.

> **What this project is not.** Character definition and roleplay operations (persona
> sheets, mood dials, a canon ledger, anti-repeat guardrails) used to live here as a
> bash prototype. They were really a re-implementation of `../the-orb`'s Character
> Engine, so they moved there (`experiments/2026-09-26-inky-gym-character-prototype/`).
> The gym is now purely about **exercising and measuring a model in a role**.

> **Verdict for the Inky role:** hire **gemma-4-E2B** — the only candidate that
> answers correctly, stays in English, and actually fixed the simulated incident
> (3/3). Two conditions: keep its temperature low (at 1.0 the fix rate drops to 1/3,
> and Hermes sends none — now pinned to 0.3 in the router preset), and confirm fixes
> independently — it sometimes misreports what it did. Inky (0.8B) is the fastest but
> fails every capability test.

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
open gui/dashboard.html          # the workout GUI (see below)
```

gemma lives behind `llama-router.service`, which is now **Hermes' live
fallback** (since 2026-09-18) — it stays running; don't stop it after tests.
Scripts skip unreachable candidates with a hint.

## The workout GUI

`gui/dashboard.html` is a single self-contained page — no server, no build step.
Open it in a browser and it becomes a SillyTavern-style console for the gym: manage
a list of **candidates** — local ones as `backend|host|port|model`, or a **remote /
frontier** one with a **Base URL** (an OpenAI-compatible `…/v1`) + **API key**, so you
can chat against and compare **Hermes' own frontier model** (its OpenRouter route)
next to the local ones. A seeded OpenRouter candidate is included — paste your key
(kept only in the browser, never in the repo) to use it. Then for any candidate:

- **Health** — is the endpoint up, and how fast does it answer?
- **Chat** — a transcript view with backend / thinking / temperature / max-tokens
  toggles (shows the model's reasoning when the visible reply is empty).
- **Explore** — the server's spec: context window, slots, template capabilities.
- **Bench** — warmup + N identical runs; tokens/s and total latency.
- **Tool probe** — send a tool schema and see whether (and how) the model calls it.
- **Graphs** — response time and tok/s over the runs *this dashboard has done*, plus a
  per-candidate comparison and a success/error tally.

It talks to llama.cpp (`/v1/chat/completions`) and ollama (`/api/chat`) directly, the
same two shapes `lib/backend.sh` uses. **Opening it — mind CORS (tested 2026-09-26):**
llama.cpp (`:8080`) returns `Access-Control-Allow-Origin: null`, so it works straight
from `file://`. **ollama (`:11434`) refuses a `file://` (null) origin with 403**, but
allows any `http://localhost` origin — so if you want the ollama candidates, serve the
page from localhost (`python3 -m http.server` in the repo root, then browse
`http://localhost:8000/gui/dashboard.html`; tunnel the port if the box is remote). No
`OLLAMA_ORIGINS`/service change needed. **Other constraints, on purpose:** the page
can't auto-read the `results/` folder, so run history is kept in the browser
(localStorage) and old transcripts are brought in with a file picker. The heavy
*scored* role tests (interview, agent-loop, heartbeat — their scorers live in bash)
stay in the terminal; the GUI links to them rather than re-implementing the scoring.

## Is the fallback actually ready?

`~/.hermes/scripts/fallback_guard.sh -v` (also runs every 5 min from cron) answers with a real
completion, not just an open port. Gemma is kept resident (`load-on-startup`) and its prompt cache is kept
warm with Hermes' real Telegram prompt: a failover turn costs **~1–2 s warm, ~30 min cold**
(19k-token prompt at ~11 tok/s on 4 cores) — see FINDINGS §11 for why, and the three settings that keep it warm.

## The equipment

| Script | What it tests |
|---|---|
| `tests/health_check.sh` | Inky's systemd unit, `/health`, `/v1/models` |
| `tests/tokens_per_second.sh` | quick single-shot tok/s for Inky |
| `tests/bench.sh` | controlled speed benchmark across candidates (warmup + N identical runs) |
| `tests/hermes_failover.sh` | **real Hermes**: forces one throwaway session (bogus primary model) to fail over to gemma. `QUICK` (default, ~5 s) passes once Hermes' own socket reaches the fallback; `FULL=1` waits for the reply. Refuses to run while gemma is busy; live gateway untouched |
| `exercise/chat.sh` | plain chat, interactive or one-shot |
| `exercise/explore.sh` | a llama.cpp server's spec: context, slots, template capabilities, sampling |
| `exercise/interview.sh` | the job interview: sysadmin questions + idle chat under a dual-mode brief |
| `exercise/agent_loop.sh` | simulated incident, full access: can it investigate *and* fix? |
| `exercise/heartbeat.sh` | liveness pings + the same incident, read-only: can it *propose* the right fix? |

Everything is plain bash + `curl` + `jq`. The agentic tests never run real
commands: models only see simulated output from `lib/scenario_port8080.sh`.

```bash
INKY_RUNS=3 VERBOSE=0 exercise/agent_loop.sh           # repeat runs, summary only
INKY_BACKEND=ollama INKY_PORT=11434 INKY_MODEL_NAME=spark-x2.5 exercise/chat.sh
CANDIDATES="Spark 4B|ollama|127.0.0.1|11434|SparkLLM/Spark-X2.5-4B" exercise/interview.sh
```

## Config

| Env var | Default | Used by |
|---|---|---|
| `INKY_HOST` / `INKY_PORT` | `127.0.0.1` / `8080`¹ | chat, explore, tokens_per_second, health_check (the router = live "inky" = gemma-4-E2B) |
| `INKY_BACKEND` | `openai` (llama.cpp) — or `ollama` | chat |
| `INKY_MODEL_NAME` | `inky` | chat |
| `INKY_MAX_TOKENS` | 512 chat · 200–300 evals | all |
| `INKY_THINKING` | `0` — `1` shows reasoning | chat |
| `INKY_TEMPERATURE` | 0.3 evals | interview, agent_loop, heartbeat |
| `INKY_RUNS` / `INKY_MAX_STEPS` | 1 / 8 (loop), 6 (heartbeat) | agent_loop, heartbeat |
| `VERBOSE` | `1` — `0` prints summaries only | agent_loop, heartbeat |
| `CANDIDATES` | built-in list | interview, agent_loop, heartbeat, bench — newline-separated `label\|backend\|host\|port\|model` |
| `BENCH_RUNS` / `BENCH_MAX_TOKENS` | 3 / 150 | bench |
| `INKY_UNIT` | `llama-router.service` | health_check (the live "inky" = gemma-4-E2B on `:8080`) |

¹ `:45072` (the old Qwen3.5-0.8B "Inky") was **retired 2026-09-24**. All `INKY_*`
defaults now point at the router on `:8080` (model alias `inky` = gemma-4-E2B).
For another candidate override the env vars
(e.g. `INKY_BACKEND=ollama INKY_PORT=11434 INKY_MODEL_NAME=spark-x2.5`) or use the GUI.
