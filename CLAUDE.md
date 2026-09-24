# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Inky's Gym: bash test/exercise scripts that evaluate small local LLMs for the
"Inky" role — Hermes Agent's local fallback model on this CPU-only OCI ARM64 box.
Results live in `FINDINGS.md`; the front door is `README.md`.

## The host (what's running where)

| Service | Port | Model | Notes |
|---|---|---|---|
| `llama-router.service` (user) | 8080 | gemma-4-E2B (+ presets) | **Hermes' live `fallback_model` since 2026-09-18 — enabled at boot, never stop it.** gemma's settings are pinned in `~/llama-presets.ini`: `temp = 0.3`, `reasoning = off`, `load-on-startup = true`, **`parallel = 1`**. The unit carries **`--timeout 3600`** (default 600 s cancels any long prefill) |
| `llama-qwen35-tiny.service` (user) | 45072 | Qwen3.5-0.8B, alias `Inky` | the previous fallback; always on — Hermes' auxiliary tasks and the `local-llama-ping` cron still use it |
| `ollama.service` (system, v0.34.1) | 11434 | `spark-x2.5`, `SparkLLM/Spark-X2.5-4B` | loads on demand, unloads when idle |
| `hermes-gateway.service` (user) | — | — | the live agent — never restart or reconfigure it |

- **RAM (23 GB total, ~7–11 GB free):** gemma ≈ 5.8 GB, spark-4B ≈ 8.4 GB,
  spark-1.7B ≈ 1.5 GB. gemma stays loaded once Hermes has used it, so **don't load
  spark-4B at all** — both together would starve the live fallback. `ollama stop <model>` to unload.
- `~/llama-presets.ini`'s `qwen35-fast` preset points at a missing `.gguf` — pre-existing, not ours.
- **Keeping the fallback alive and warm** (`~/.hermes/scripts/`, both silent unless something breaks):
  `fallback_guard.sh` runs from cron every 5 min (`hermes cron` job `fallback-guard`, delivers to Telegram):
  starts the router if down, proves gemma with a real completion, is busy-aware (a working model is never
  "down"), checks `fallback_model` drift. `fallback_warm.sh` (called by the guard) sends gemma Hermes' real
  Telegram system prompt + tool schemas (the live session's stored prompt with `Model:`/`Provider:` rewritten
  as Hermes does on failover) so the ~19k-token prefix is already in cache. Both are backed up daily by `backup_hermes.sh`.
- **Cold vs warm is the whole story on this CPU:** a cold first failover turn re-reads ~19k tokens at 40→11 tok/s
  = **~30 min**; warm it is **1–2 s**. Three things must hold or it silently goes cold again: router `--timeout 3600`
  (else cancelled at 600 s), preset `parallel = 1` (with 4 slots the next task evicts the warm prompt into a RAM
  cache that fails to restore), and nobody restarting the router (the cache lives in the process). See FINDINGS §11.
- **Don't fire extra identical requests at gemma** — identical prompts don't share in-flight work, they queue and
  split the 4 cores; killing the client does NOT cancel the server-side prefill. `fallback_warm.sh` refuses to stack.
- `pkill -f`/`pgrep -f` patterns can match your own shell's command line; use `pgrep -x curl` or `[x]` patterns.
- Hermes' `fallback_model` (`~/.hermes/config.yaml`) points at gemma on 8080. Change it only
  when asked, with `~/.hermes/scripts/set_fallback_model.py <model> <port>` (it edits just those lines).
  Pre-switch backup: `~/.hermes/config.yaml.2026-09-18-pre-gemma-fallback.bak`.

## Layout

```
lib/backend.sh           llm_chat / llm_message / llm_tool_calls / candidate plumbing — both API shapes
lib/scenario_port8080.sh the simulated incident, its scorer, and the shared tool-loop runner
lib/repeat.sh           near_repeat: fuzzy "did he just re-use a sentence?" check for the guardrail (FINDINGS §12c)
lib/canon.sh            a character's persistent fact ledger: lookup, extract, dedupe, contradiction check (FINDINGS §12)
tests/                   health_check.sh, tokens_per_second.sh (Inky only), bench.sh (any candidate), hermes_failover.sh (real Hermes -> gemma), canon.sh (ledger unit tests), repeat.sh (repeat-detector unit tests)
exercise/                chat, explore, character, interview, agent_loop, heartbeat
characters/*.json        character sheets (persona, mood bands, per-band voice examples)
results/                 raw transcripts from dated runs — cite these from FINDINGS.md
```

Every script is plain bash + `curl` + `jq`. Syntax-check with `bash -n`. There's no build or test runner.

## Conventions and gotchas

- **Two backends.** `openai` = llama.cpp `/v1/chat/completions`; `ollama` = native
  `/api/chat`. ollama's OpenAI-compatible endpoint **ignores the thinking toggle**, so
  ollama models must go through `/api/chat`. Always route through `lib/backend.sh` —
  don't hand-roll curl calls.
- **Thinking off by default.** These are small reasoning models: left to think, they
  spend the whole token budget on `<think>` and never answer.
- **Tool-call arguments** come back as a JSON *string* from llama.cpp and an *object*
  from ollama. `llm_tool_calls` normalizes both.
- **Candidates** are `label|backend|host|port|model` lines. Override with the
  `CANDIDATES` env var, **newline-separated** (labels contain spaces).
- **Pin sampling across candidates.** The eval scripts default to `INKY_TEMPERATURE=0.3`;
  server defaults differ (0.7–1.0).
- **The mock environment** (`scenario_run_command`) must be called directly, **never
  as `$(...)`** — a subshell silently discards its state (this bug invalidated v1).
  Match commands on **exact tokens**, not substrings (`ss` matched `-sS`; `ps` matches `https`).
- **No real commands in agentic tests.** Models under test only ever see simulated
  output. Don't give them a real shell.
- **Config is env vars, not flags** (`INKY_*`), so `$*` stays free for the prompt.

## Methodology (learned the hard way — see FINDINGS.md)

- One run isn't evidence: use `INKY_RUNS=3` or more before concluding anything.
- Throughput claims come from `tests/bench.sh` (warmup + N identical runs), never a single reading.
- Unit-test the mock and the scorer before trusting a result — half the bugs found were in the harness.
- Save raw output to `results/<date>-<test>.txt`. Write conclusions in `FINDINGS.md`
  (Question → Setup → Result → Verdict), and update the README scorecard.

## Git

This repo pushes to `jibjabjog/ai-gym` (private) as `jibjabjog`. It's a standalone
repo nested inside `/home/huey`'s own repo, which no longer tracks this folder. The user drives
commits and pushes explicitly — don't commit or push unasked.
