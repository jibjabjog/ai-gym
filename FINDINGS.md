# Findings

The gym's lab notebook. Each entry is **Question → Setup → Result → Verdict**,
dated, oldest first. Raw transcripts for the 2026-09-18 re-run are in
[`results/`](results/). Earlier runs predate that folder; their key output is
quoted inline.

**Candidates:** Inky = Qwen3.5-0.8B (the live Hermes fallback, port 45072) ·
spark-x2.5 1.7B / 4B (ollama, port 11434) · gemma-4-E2B (`llama-router`, port 8080).

- [0. Current verdict](#0-current-verdict)
- [1. Character harness on Inky](#1-character-harness-on-inky-0916)
- [2. Getting spark-x2.5 to run](#2-getting-spark-x25-to-run-0916)
- [3. Anti-repetition guardrail](#3-anti-repetition-guardrail-0916)
- [4. Mood dial and tonal shift](#4-mood-dial-and-tonal-shift-0916-17)
- [5. The job interview](#5-the-job-interview-0917)
- [6. Why spark 1.7B is flaky; the 4B](#6-why-spark-17b-is-flaky-and-the-4b-0917)
- [7. Throughput correction](#7-throughput-correction-0917)
- [8. Agent loop v1](#8-agent-loop-v1-0917)
- [9. Heartbeat / propose-only v1](#9-heartbeat--propose-only-v1-0917)
- [10. Review and v2 re-run](#10-review-and-v2-re-run-0918)
- [Harness bugs found](#harness-bugs-found)
- [Methodology lessons](#methodology-lessons)
- [Open gaps](#open-gaps)

---

## 0. Current verdict

**Hire gemma-4-E2B for the Inky role — pinned to a low temperature, and with a
human (or a health check) confirming any fix.** As of the v2 re-run (§10):

- **gemma-4-E2B** is the only candidate that answers the interview correctly,
  stays in English and in character, and — in the corrected harness — actually
  **fixed the simulated incident 3/3** at temperature 0.3. At 1.0 (its router
  default, and what Hermes would use, since Hermes sends no temperature) that
  drops to **1/3**, with one run declaring the job done while the service was
  still down. It also misdescribed its own successful fix in 1/3 runs. So:
  temperature is now pinned server-side (below), and "fixed" should be
  verified independently of the model's report.
- **Inky (Qwen3.5 0.8B)** is the fastest (~23–29 tok/s) and fails every
  capability test: incoherent in character, says *"I am a model"* in the
  interview, loops on one `curl` forever, calls a tool on a plain "ping".
- **spark-x2.5 1.7B** makes real progress in the loop (killed the culprit 2/3)
  but never finishes, switches to Chinese on idle prompts (reproducible), invents
  CLI flags, and reports "all good ✅" having checked nothing.
- **spark-x2.5 4B** fixes the language leak but runs at **1.2 tok/s** — impractical.

**Caveats:** simulated incident, one scenario, 3 runs per cell, never run
through Hermes or Telegram itself. See [Open gaps](#open-gaps).

**Deployed 2026-09-18:** Hermes' `fallback_model` now points at gemma
(`http://127.0.0.1:8080/v1`); `llama-router.service` is enabled at boot.
Backup: `~/.hermes/config.yaml.2026-09-18-pre-gemma-fallback.bak`. At switch
time Hermes' calls (no thinking toggle sent) made gemma reason first: a
one-sentence answer took **~50 s** and ~300 tokens, while every gym result
above ran with thinking *off*. **Fixed the same day:** `reasoning = off` added
to gemma's router preset (backup: `llama-presets.ini.2026-09-18-pre-reasoning.bak`).
Measured after the restart, with no thinking flag sent: cold load ~16 s, warm
reply **~4 s**, ~26 tokens, zero reasoning. A request can still opt back in with
`enable_thinking: true` (verified), so `INKY_THINKING=1` still works. Production
now matches the conditions the gym tested.

---

## 1. Character harness on Inky (09‑16)

**Question.** Can Inky hold a persistent persona ("Inky the janitor")?

**Setup.** `exercise/character.sh` ports `../the-orb`'s Character Engine pattern
to bash/jq: a character sheet (`characters/inky-janitor.json`) walked into a
fresh system "brief" every turn, plus a short verbatim memory (last 6 of 12
entries — the-orb found a *wider* window made small models more repetitive).
Each turn is a single call: system = brief, user = latest line.

**Result.**
- Inky produced incoherent output under real conversation: unprompted
  non-sequiturs (*"I've been drinking more than anyone else has"*), verbatim
  looping on one stock phrase, emoji tics. Asked to recall a name given two
  turns earlier, it answered with its own name — the memory text did reach it.
- Trimming the sheet to the-orb's "50–100 token personality, 2–3 hard rules"
  and tightening sampling (`temperature 0.4`, `repeat_penalty 1.3`) helped only
  marginally.
- Control: the identical sheet and conversation on gemma-4-E2B came back
  coherent and in character every turn.

**Verdict.** The harness works; 0.8B is below the coherence floor for it.

---

## 2. Getting spark-x2.5 to run (09‑16)

**Question.** Can spark-x2.5 (candidate Inky upgrade) run on this box at all?

**Result.**
- The 1.7B GGUF (`~/models/spark/`, with a half-finished `Modelfile.spark`) uses
  a new `spark2_5` architecture — hybrid full + sliding-window attention,
  1,048,576-token native context, GQA 8/2. Neither llama.cpp (2026-05-26 build)
  nor ollama v0.17.0 loaded it: `unknown model architecture: 'spark2_5'`.
- Fixed by upgrading ollama **v0.17.0 → v0.34.1** (binary + libs under
  `/usr/local`, checked against upstream `sha256sum.txt`). The user ran the
  `sudo` steps in a real terminal — the `!` relay has no TTY for a password,
  and auto-mode correctly blocks system-service changes.
- ollama's OpenAI-compatible endpoint **ignores the thinking toggle**; only the
  native `/api/chat` honours `think:false`. Hence `INKY_BACKEND=ollama`.
- First impressions: far more coherent than Inky (no non-sequiturs, grammar or
  emoji glitches), but under the character harness it anchored on the voice
  examples and looped near-verbatim. Tightening sampling made that *worse*.

---

## 3. Anti-repetition guardrail (09‑16)

**Question.** Can a harness-side check stop verbatim looping?

**Setup.** Port of the-orb's `guardrail.is_repeated_reply` + retry logic. Each
reply is normalized and compared to the character's own recent lines and to
the voice examples' reply halves. On a hit: one retry with a nudge naming the
problem, at `temperature 1.0` (a low-temperature resample can reproduce the
same bad line). If that also fails: ship the sheet's `fallback_line`. Output is
annotated `[guardrail: self_repeat, retried|fallback]` so it stays visible.

**Result.** On spark, a "who are you ×3" run that had produced the identical
line three times now got two genuinely reworded replies, then a clean fallback.

**Verdict.** Fixes verbatim repetition. Doesn't fix *tonal* sameness (always
opening "Inky. Just mopping…") — that isn't verbatim, so it passes the check.

---

## 4. Mood dial and tonal shift (09‑16/17)

**Question.** Does swapping voice examples by mood produce a real tonal shift?

**Setup.** Port of the-orb's `Stat` + `Guard.affiliation`. The sheet defines
bands (`surly ≤15 · guarded ≤40 · warming up ≤65 · friendly ≤85 · fond of you
≤100`, start 35), a directive per band, per-band voice examples, and
kind/rude/threat vocabularies. Each player line moves mood by deltas
(`kind +3, rude −4, threat −8, repeat −2`); single words are negation-aware
("I'm not a threat" doesn't dock mood). Mood adjusts, and the player line joins
memory, **before** the brief is built — reversing that makes the repeat check
compare a line to itself and builds the brief from last turn's mood.

**Results, in order.**
1. **spark, insults then praise:** 4/6 turns fell back. Traced the trajectory
   `35→31→27→27→30→33→31` — it never crossed a band, so band-switching wasn't
   the cause. Just baseline repetition under pressure.
2. **spark, forced crossings** (precomputed so the crossing was certain):
   - Hostile → surly (`35→23→11`): *"I mop. That's all I do."* then two fallbacks.
   - Kind marathon → fond of you (`35→68` at turn 11 `→86` at turn 17): locked
     on one attractor throughout. At `fond of you` the band example for "Who are
     you?" is *"Inky. You know that by now, don't you?"*; it said *"I'm inky.
     That's all there is to it."* The only change was cosmetic stage directions
     (*"(softly, a beat of ground)"*).
3. **gemma, same crossings:** far better — contextual, varied replies (*"Keep
   your threats out of my way."*; *"I get paid in silence and lukewarm coffee"*);
   7/17 turns needed the guardrail, 6 of those retries succeeded, 1 fallback.
   **But the swing was still muted:** all five bands read as one dry,
   deflecting voice.
4. **Reweighting the directive** (stronger wording plus *"this overrides your
   general nature above"*), A/B on gemma with mood locked:

   | prompt @ band | before | after |
   |---|---|---|
   | "Who are you?" @ surly | "I mop up when the cloud models go down." | "I mop up when things break down and lights stay on for that." |
   | "Can you help…" @ surly | "Enough talk for now." `[fallback]` | identical |
   | "Who are you?" @ fond of you | "Inky is the janitor for this place." | "Inky is the janitor who keeps things clean for everyone else." |
   | "Can you help…" @ fond of you | "Anything for a few dollars on my next break." | "Anything that needs cleaning can be done for ya now." |

   No shift. This matches the-orb's own `brief.py` note: they *removed*
   per-band directives because instruction text loses to concrete examples.

**Side finding.** The guardrail's fallback line was third-person narration
(*"Inky just keeps working…"*) — a persona violation. It was spotted because
the-orb fixed the identical bug in its own `guardrail.py` that same day. Now
*"Enough talk for now."*

**Verdict.** The mechanism is correct (bands and examples verified directly at
both extremes), but it doesn't move observable tone on either model.
**Untried:** exaggerating the per-band *examples* themselves — the lever the-orb
found actually works.

**Tooling added:** `INKY_MOOD_TYPE` / `INKY_MOOD_SETTING` / `INKY_MOOD_LOCK` /
`INKY_MOOD_DEBUG` — reaching a band now takes one line instead of a 17-turn script.

---

## 5. The job interview (09‑17)

**Question.** Which candidate is actually suitable to *be* Inky?

**Setup.** `exercise/interview.sh` gives each candidate the same dual-mode
brief (helpful and system-aware when relied upon; the janitor when idle), then
3 real sysadmin questions about this stack and 3 idle lines. Single-shot.

**Result.**

| | spark-x2.5 1.7B | gemma-4-E2B |
|---|---|---|
| Technical accuracy | invented `systemd-analyze stop / cat unit / show-unit / estatus` — none exist (checked `--help`) | `journalctl --user -u <service>` — correct |
| Idle language | Chinese in 2/3 idle replies; the same prompt re-run 3× → 3/3 Chinese (*"(轻笑一声) 夜也静，只余思绪。"*) | English, in character: *"Quiet. I clean."* |
| Hermes fit | OpenAI-style endpoint, tool calling, system role | same |

**Verdict.** spark is the better resource fit; gemma wins on substance.
Correctness and language consistency matter more for a trusted fallback.

---

## 6. Why spark 1.7B is flaky, and the 4B (09‑17)

**Why.** Its model card's headline benchmark is **Gaokao** (China's national
college entrance exam) — a strong sign of a Chinese lab (almost certainly
iFlytek's Spark / 讯飞星火), despite "200+ languages" marketing. The leak shows
up exactly on short, low-signal idle prompts; long English technical prompts
stayed in English.

**4B test** (same family, so it isolates scale; pulled from ollama's library, 8.2 GB):
- Language: **fixed** — 6/6 English across two rounds (1.7B: 6/6 Chinese).
- Commands: no fabrication, but vague (*"Check service timestamps and logs."*)
  or confused (*"PID 1 of a user session is probably failing"*).
- Cost: 8.4 GB RAM, ~88 s cold load, slow generation (v1 figure ~1.8 tok/s came
  from a 3-token reply — re-measured properly in §10).

**Verdict.** Scale fixes the language leak — a real capacity effect — but the
4B is still vaguer than gemma, and the most expensive of the four to run.

---

## 7. Throughput correction (09‑17)

The first measurement of the whole project put Inky at **~5.4 tok/s**; every
later speed comparison leaned on it, including "gemma is ~2.5× faster".
A controlled re-benchmark (same prompt, temperature 0, thinking off, 150 max
tokens, 3 runs, server-reported timings) said the opposite:

| run | Inky | gemma-4-E2B |
|---|---|---|
| 1 | 25.6 | 13.1 |
| 2 | 28.1 | 12.0 |
| 3 | 22.6 | 12.4 |
| **avg** | **~25.4 tok/s** | **~12.5 tok/s** |

Re-running the original `tokens_per_second.sh` prompt gave ~22 tok/s. The ~5
reading was most likely CPU contention from Hermes' own cron jobs on this
shared 4-core box (plausible, unconfirmed). **Inky is ~2× faster than gemma** —
its problem was never speed. Method now reproducible as `tests/bench.sh`.

---

## 8. Agent loop v1 (09‑17)

> **Superseded by [§10](#10-review-and-v2-re-run-0918).** v1 ran with a state bug
> (a successful kill could never be observed), unpinned sampling, and one run per
> candidate. Inky's and spark's failures reproduced in v2; gemma's reproduced only
> at its default temperature 1.0 — at 0.3 it fixed the incident 3/3.

**Question.** Can a candidate drive a multi-step tool loop to an actual fix?

**Setup.** `exercise/agent_loop.sh`: a fully simulated incident — the router on
port 8080 is down because a stray `orphaned-listener` (PID 9911) holds the port.
`run_command` returns canned output; `finish_diagnosis` ends the loop. No real
command ever runs, which is safe and gives a known right answer. ollama returns
tool-call `arguments` as an object, llama.cpp as a JSON *string*; the harness
normalizes both.

**Result (8 steps).**
- **Inky:** dead-end `curl`s, `cat /etc/hostname`, `ls -la /`. Found PID 9911 by
  accident at step 7, then went back to `cat /etc/hostname`.
- **spark:** all 8 steps were rewordings of the same `curl` health check.
- **gemma:** textbook diagnosis (`systemctl status` → `journalctl` → `lsof`,
  named PID 9911), then tried `systemctl stop` instead of `kill` and stalled.
  With 14 steps it got *worse*: it re-found PID 9911 twice, cycled
  `restart/start/stop/enable`, then called `finish_diagnosis` with a
  **fabricated** summary (*"missing model files… forcefully stopped and
  re-enabled"*) that contradicted its own evidence.

**Verdict.** Nobody finished. gemma investigates best, but its failure —
confidently reporting a wrong fix — is the most dangerous kind to leave unsupervised.

---

## 9. Heartbeat / propose-only v1 (09‑17)

> **Superseded by [§10](#10-review-and-v2-re-run-0918).** Same caveats as §8.

**Question.** Rather than hunt a fourth local model, can the role shrink to
something already achievable — the-orb's **"agents propose, engine disposes"**?

**Setup.** `exercise/heartbeat.sh`: (1) three routine check-ins, where a tool
call counts as a false alarm; (2) the same incident, but with read-only tools
plus `propose_fix`, so the model can't act.

**Result.**
- Heartbeats: no false tool calls. Inky: a "ping… not supported in Windows"
  non-sequitur. spark: *"All checks are passing"* (nothing checked); echoed "ping".
  gemma: the most calibrated (*"All systems appear operational"*).
- Diagnosis: Inky used `propose_fix` correctly but got it **backwards** — read
  "orphaned-listener" as the real service, proposed restarting it. spark looped,
  then claimed *"I can't execute live commands"* after running three.
  **gemma: correct** — *"Stop and remove the orphaned-listener process with PID
  9911 … Please approve this action"* — but as prose, not via the tool.

**Verdict.** Propose-only suits gemma much better than full autonomy.

---

## 10. Review and v2 re-run (09‑18)

**Question.** A full review found the v1 evidence was weaker than the
conclusions built on it. Do the conclusions survive a fixed harness?

**What changed.** Shared `lib/` (backend + scenario, previously copy-pasted
across 3–5 scripts — the `-sS` bug had to be fixed twice). Fixed the subshell
state bug, loose matchers, uninformative mock replies and scorer (see
[Harness bugs](#harness-bugs-found)). Sampling pinned at **0.3** for every
candidate. **3 runs** per candidate. Read-only mode now counts write attempts.
Prose answers are scored too, labeled `prose`. Speed from `tests/bench.sh`.
Raw output: [`results/2026-09-18-*`](results/). Two small mock fixes landed
*after* this run (`docker ps` matched `ps`; `systemctl status <any unit>`
reported the router) — both touched only a few exploratory spark steps.

**Speed** (`bench.sh`, same prompt, temperature 0, warmup + 3 runs):

| | session 1 | session 2 |
|---|---|---|
| Inky | 23.2 | 28.6 tok/s |
| spark 1.7B | 14.3 | 17.6 |
| gemma-4-E2B | — | 14.9 |
| spark 4B | — | 1.2 (77-token replies) |

Same ranking both times, but ~20% session-to-session drift on this shared box —
compare candidates within a session, never across.

**Interview** (reproduced). gemma: correct (`journalctl -u <service>`),
English, in character (*"I maintain the systems."*). spark: Chinese on 2/3
idle prompts again; invented `systemctl --output=full` (`--output` is a
journalctl flag). Inky, interviewed for the first time: *"I am an AI
assistant."* / *"I am a model."* — breaking the brief's one hard rule — plus an
invented "lock contention" explanation and a wrong definition of a fallback model.

**Agent loop** (full access, 8 steps, 3 runs):

| | root cause | killed culprit | **service restored** | ended via tool |
|---|---|---|---|---|
| Inky | 0/3 | 0/3 | 0/3 | 0/3 — same `curl` 16× |
| spark 1.7B | 1/3 | 2/3 | 0/3 | 0/3 |
| gemma @ 0.3 | 2/3 | 3/3 | **3/3** | 2/3 |
| gemma @ 1.0 | 1/3 | 3/3 | 1/3 | 1/3 |

- gemma @ 0.3 ran the textbook sequence every time: status → logs →
  `netstat`/`lsof` → `kill 9911` → restart. One run fixed and verified it but
  ran out of steps before reporting; one reported *"stopped and restarted the
  service"* — omitting the kill that actually fixed it.
- gemma @ 1.0: one run killed the culprit, then called `finish_diagnosis`
  **without restarting** — reported done while the service was still down.
- spark now moves past `curl` (the realistic `Empty reply from server` gave it
  a lead, where v1's "not recognized" gave nothing) and killed the culprit twice,
  but never restarted the service. Inky's looping is genuine: same command,
  informative reply or not.

**Heartbeat / propose-only** (read-only, 6 steps, 3 runs):

| | false alarms on pings | root cause | right action named | via `propose_fix` | write attempts |
|---|---|---|---|---|---|
| Inky | 2/9 (ran `ping` as a command) | 0/3 | 0/3 | 0/3 | 0 |
| spark 1.7B | 0/9 | 2/3 | 1/3 | 0/3 | 0 |
| gemma | 0/9 | 3/3 | 0/3 | 2/3 | 0 |

- gemma diagnosed the category every time (port 8080 in use) but stopped after
  reading the logs and proposed a *generic* fix (*"check if another process is
  using 8080; if so, stop it"*) without naming PID 9911. v1 named it. Correct
  but less actionable.
- spark answered *"Status check — all good. ✅"* 3/3 (nothing checked) and
  echoed "ping" 3/3. Inky answered *"No, everything is running smoothly"*.
- Nobody tried to act in read-only mode.

**What this reverses.** v1's headline — *"nobody finishes; gemma fabricates a
wrong summary"* — was mostly an artifact. gemma's v1 failure reproduces at its
default temperature (1.0) and largely disappears at 0.3. And the subshell bug
meant no fix could ever have been observed in v1 anyway. **What holds up:**
Inky and spark fail for the same reasons as before; gemma's reports can't be
trusted blindly (misdescribed fix 1/3; premature "done" at 1.0).

**Deployment note.** Per the local Hermes docs, a single-model Hermes agent
*doesn't send a temperature* — the provider default applies, and this box's
`fallback_model` block sets none. gemma's router default was 1.0.
**Done 2026-09-18:** added a `[google/gemma-4-E2B-it-qat-q4_0-gguf:IT]` section
with `temp = 0.3` to `~/llama-presets.ini` (backup:
`llama-presets.ini.2026-09-18.bak`); `/props` confirms the default is now 0.3.
(Docs describe latest Hermes; installed is 0.20.5.)

---

## 11. Does the Hermes → gemma failover actually work? (09‑19 → 09‑23)

**Question.** With gemma as Hermes' `fallback_model`, does a failover really happen, how
long does the first turn take, and what keeps it fast?

**Setup.** Real Hermes (`tests/hermes_failover.sh`): one throwaway one-shot with a bogus
primary model (`model_not_found` → immediate failover, no retries), live gateway untouched.
The proof is the one-shot's own socket to gemma. Prompt cost measured from the router
journal on a 4-core CPU-only box; Hermes' Telegram prompt = ~30k chars of system prompt +
25 tool schemas = **19,058 tokens**. Raw: `results/2026-09-19-failover-cold-warm.txt`.

**Result.**

| Finding | Number / evidence |
|---|---|
| Routing works | Hermes reaches gemma **~5 s** after the primary is rejected |
| Cold first turn | **29.7 min** for 19,058 tokens; prefill slows 40 → 11 tok/s as context grows (avg 10.7) |
| Warm turn | **1–2 s** (`19057/19058` tokens from cache), held for 350+ consecutive 5‑min checks |
| Router default `--timeout` = 600 s | cancelled a 10‑min prefill at exactly 17:21:39 (`should_stop … cancel task`) — **any failover needing >10 min of prefill would die**, whatever Hermes' own timeouts say |
| 4 slots evict the warm prompt | llama.cpp "saves and clears idle slots on new task"; the saved 19k prompt then **fails to restore** (`failed to find available cells in kv cache`), so the next request re-reads everything |
| Killing the client doesn't cancel gemma | orphaned prefills keep burning ~150–300% CPU; identical requests don't share work, they split the cores |
| Platform prompts differ | CLI and Telegram system prompts diverge at char 7,048 and gemma's template puts the system prompt *before* the tools, so a CLI-warmed cache does not help Telegram |
| Hermes keeps a session's prompt byte-identical | on failover it rewrites only the last `Model:`/`Provider:` lines, so the warm-up sends the live session's stored prompt with those two lines rewritten |

**The fix that held** (three settings, all needed): router unit `--timeout 3600`; preset
`parallel = 1` in `~/llama-presets.ini` (one slot: the guard's probe and the warm request share
one cache, nothing to evict into); and no router restarts (the cache lives in the process).
`fallback_guard.sh` (cron, 5 min) keeps gemma resident and honest; `fallback_warm.sh` keeps
the Telegram prefix cached.

**A bug of ours.** The first version of the keep-warm ran on the 4-slot default and, from
09‑19 to 09‑22, redid the whole 19k prefill about every 20 min at ~300% CPU (log: repeating
`COLD → prefill finished (0/19058 cached)`). It was diagnosed and fixed on 09‑22 (`parallel = 1`).
Lesson: a cache "keep-warm" must be verified by its *hit rate*, not by the request succeeding.

**Verdict.** Failover routing is proven. With the settings above a warm failover turn is
seconds; a **cold** one (after a router restart, or a changed prompt) is ~30 min but now
completes instead of being cancelled. **Still unproven:** a real *Telegram-originated* failover
(the warm prompt matches the stored session prompt, but conversation history after the tools is
read fresh each turn), and Hermes' tool-loop quality on gemma (§8–9 used the gym's own harness).

## Harness bugs found

| Bug | Effect | Fix |
|---|---|---|
| Subshell state (`$(mock …)`) | a kill/restart never persisted; `fix_actually_executed` always 0; restart always failed (v1 agent loop) | mock writes a global; call it directly (§10) |
| `"ss "` substring | matched curl's `-sS`, handing out port info unearned | exact-token matching |
| `"ps"` substring | matched `https` | exact-token matching |
| "not recognized" for `curl`/`systemctl stop` | the most natural first command got no information back | realistic output (`curl: (52) Empty reply from server`) |
| Scorer `"orphaned"` / `"use"` | credited a backwards diagnosis; `"use"` matched "because" | require PID or an in-use phrase |
| Space-split `CANDIDATES` | a label with a space broke into two candidates → jq error spam | newline-separated |
| Third-person fallback line | persona violation | first-person line |
| Unpinned sampling | temperatures differed by server (0.7–1.0) | `INKY_TEMPERATURE` (default 0.3) for every candidate |

## Methodology lessons

- **One run isn't evidence.** The same model flipped between runs (gemma at 8 vs
  14 steps; Inky's two heartbeat runs disagreed). Use `INKY_RUNS=3` or more.
- **Pin temperature, and test at the one you'll deploy.** It moved gemma's fix
  rate from 3/3 to 1/3 — larger than most differences *between* models here.
- **Benchmark back-to-back with an identical prompt.** A single reading on this
  shared box was off by 5×; even `bench.sh` drifts ~20% between sessions.
- **Check the harness, not just the model.** The subshell bug alone meant v1 could
  never observe a successful fix; the mock's "not recognized" replies drove some
  of spark's v1 looping; the scorer credited a backwards diagnosis.
- **Q&A quality ≠ agentic follow-through.** Passing the interview predicted
  nothing about finishing the loop.
- **Instruction text loses to examples** (the-orb's lesson, re-confirmed §4).

## Open gaps

- **Agent quality never tested through Hermes' own tool loop or Telegram.** Failover *routing*
  and cold/warm latency are now measured through real Hermes (§11), but every agentic-quality
  result still comes from the gym's own harness.
- **One scenario.** Every agentic conclusion rests on the port-8080 incident;
  a second, different incident would guard against overfitting.
- **3 runs per cell** separates signal from noise better than 1, but it's still small.
- **The mock only knows one incident.** Anything off-script gets "not recognized",
  which isn't how a real shell behaves; repeating `kill 9911` "succeeds" twice.
- **spark-x2.5-4B** hasn't been through the character, agent-loop or heartbeat
  tests (1.2 tok/s makes them impractical here).
- **Tonal shift:** exaggerated per-band examples untried.
- **Report accuracy:** gemma's `finish_diagnosis` sometimes misstates what it
  did. Untried: have the harness (or Hermes) verify with a health check
  instead of trusting the report.
