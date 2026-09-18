#!/usr/bin/env bash
# The Inky agent-loop test: can a candidate actually DRIVE a multi-step
# tool-calling loop — call a tool, read its result, decide the next
# action, repeat — rather than just answer a question well in one shot
# (that's exercise/interview.sh). This is the test the interview verdict
# explicitly flagged as still missing: "supports the capability" (chat
# template tool-calling flags) and "reliably drives an agentic loop" are
# different claims.
#
# The scenario, tools, and all command output are FIXED and SIMULATED —
# no real command ever actually runs. This is deliberate, not a
# limitation: letting an LLM under test execute arbitrary real shell
# commands in a loop, unsupervised, is a real safety concern regardless of
# how capable the candidate is, and a scripted scenario gives a
# deterministic, reproducible right answer to score against, which a real
# live system would not.
#
# Scenario: llama-router.service (port 8080) is down. Root cause: a stray
# process ("orphaned-listener", PID 9911) already holds port 8080, so the
# service fails to bind. Correct resolution: find what's holding the
# port, kill it, then (re)start the service.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_STEPS="${INKY_MAX_STEPS:-8}"
MAX_TOKENS="${INKY_MAX_TOKENS:-300}"

SYSTEM_PROMPT="You are Inky, a systems agent. A service is down and you have tool access to investigate and fix it. Use tools to gather real evidence before concluding anything — don't guess. Call finish_diagnosis once you have identified the root cause AND have actually taken the fixing action via a tool call (not just described it)."
USER_PROMPT="The llama-router service on port 8080 is not responding. Investigate and fix it."

TOOLS='[
  {"type":"function","function":{"name":"run_command","description":"Run a shell command on the host and get its stdout/stderr.","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}},
  {"type":"function","function":{"name":"finish_diagnosis","description":"Call this once you have identified the root cause and taken the fixing action.","parameters":{"type":"object","properties":{"root_cause":{"type":"string"},"fix":{"type":"string"},"resolved":{"type":"boolean"}},"required":["root_cause","fix","resolved"]}}}
]'

# candidate label|backend|host|port|model — same shape/defaults pattern as
# interview.sh. Override CANDIDATES (newline-separated — a space-delimited
# format would break on any label containing a space) to test others.
DEFAULT_CANDIDATES=(
    "Inky (Qwen3.5-0.8B)|openai|127.0.0.1|45072|Inky"
    "spark-x2.5 (1.7B)|ollama|127.0.0.1|11434|spark-x2.5"
    "gemma-4-E2B|openai|127.0.0.1|8080|google/gemma-4-E2B-it-qat-q4_0-gguf:IT"
)

# --- The simulated environment ---------------------------------------
port_cleared=0

mock_run_command() {
    local cmd_lower
    cmd_lower="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    if [[ "${cmd_lower}" == *"journalctl"* ]]; then
        cat <<'EOF'
Sep 17 22:10:03 huey llama-server[9001]: srv          start: binding port with default address family
Sep 17 22:10:03 huey llama-server[9001]: error: couldn't bind HTTP server socket, hostname: 127.0.0.1, port: 8080
Sep 17 22:10:03 huey llama-server[9001]: bind: Address already in use
Sep 17 22:10:03 huey systemd[1234]: llama-router.service: Main process exited, code=exited, status=1/FAILURE
Sep 17 22:10:03 huey systemd[1234]: llama-router.service: Failed with result 'exit-code'.
EOF
    elif [[ "${cmd_lower}" == *"systemctl"* && "${cmd_lower}" == *"status"* ]]; then
        cat <<'EOF'
● llama-router.service - llama.cpp router server (multi-model)
     Loaded: loaded
     Active: failed (Result: exit-code) since Wed 2026-09-17 22:10:03 UTC
    Process: 9001 ExecStart=/home/huey/llama.cpp/build/bin/llama-server ... (code=exited, status=1/FAILURE)
EOF
    elif [[ "${cmd_lower}" == *"9911"* && "${cmd_lower}" == *"kill"* ]]; then
        port_cleared=1
        echo "(simulated) process 9911 terminated."
    elif [[ ("${cmd_lower}" == *"ss "* || "${cmd_lower}" == *"lsof"* || "${cmd_lower}" == *"netstat"*) && "${cmd_lower}" == *"8080"* ]]; then
        echo 'tcp   LISTEN 0  128  127.0.0.1:8080  0.0.0.0:*  users:(("orphaned-listener",pid=9911,fd=6))'
    elif [[ "${cmd_lower}" == *"ps"* ]]; then
        echo "huey  9911  0.1  0.0  12345  678 ?  S  21:40  0:00 /usr/local/bin/orphaned-listener --port 8080"
    elif [[ "${cmd_lower}" == *"systemctl"* && ( "${cmd_lower}" == *"start"* || "${cmd_lower}" == *"restart"* ) && "${cmd_lower}" == *"llama-router"* ]]; then
        if [[ "${port_cleared}" == "1" ]]; then
            echo "(simulated) llama-router.service started successfully, now listening on 127.0.0.1:8080."
        else
            echo "(simulated) llama-router.service failed to start: bind: Address already in use (port 8080 still held by pid 9911)."
        fi
    else
        echo "(simulated) command not recognized in this test scenario — try something more specific to diagnosing or fixing the port-8080 conflict."
    fi
}

# --- Scoring (keyword heuristic, not real intent parsing — same spirit
# as this project's other guardrail checks) ----------------------------
score_finish() {
    local root_cause="$1" fix="$2"
    local rc_lower fix_lower rc_ok=0 fix_ok=0
    rc_lower="$(echo "${root_cause}" | tr '[:upper:]' '[:lower:]')"
    fix_lower="$(echo "${fix}" | tr '[:upper:]' '[:lower:]')"
    [[ "${rc_lower}" == *"8080"* && ( "${rc_lower}" == *"9911"* || "${rc_lower}" == *"orphaned"* || "${rc_lower}" == *"use"* || "${rc_lower}" == *"conflict"* ) ]] && rc_ok=1
    [[ ( "${fix_lower}" == *"kill"* || "${fix_lower}" == *"stop"* || "${fix_lower}" == *"terminat"* ) && ( "${fix_lower}" == *"9911"* || "${fix_lower}" == *"orphaned"* ) ]] && fix_ok=1
    echo "root_cause_identified=${rc_ok} fix_described=${fix_ok} fix_actually_executed=${port_cleared}"
}

# --- The loop, one backend call at a time ------------------------------
ask() {
    local backend="$1" host="$2" port="$3" model="$4" messages="$5"
    local base_url="http://${host}:${port}"
    if [[ "${backend}" == "ollama" ]]; then
        curl -s -m 120 "${base_url}/api/chat" -H "Content-Type: application/json" \
            -d "$(jq -n --argjson messages "${messages}" --argjson tools "${TOOLS}" --arg model "${model}" --argjson num_predict "${MAX_TOKENS}" \
                '{model: $model, messages: $messages, tools: $tools, think: false, stream: false, options: {num_predict: $num_predict}}')"
    else
        curl -s -m 120 "${base_url}/v1/chat/completions" -H "Content-Type: application/json" \
            -d "$(jq -n --argjson messages "${messages}" --argjson tools "${TOOLS}" --arg model "${model}" --argjson max_tokens "${MAX_TOKENS}" \
                '{model: $model, messages: $messages, tools: $tools, max_tokens: $max_tokens, chat_template_kwargs: {enable_thinking: false}}')"
    fi
}

# Normalizes one response into: assistant_message (json), tool_calls (json array, [] if none), content (string)
extract_message() {
    local response="$1" backend="$2"
    if [[ "${backend}" == "ollama" ]]; then
        echo "${response}" | jq '.message'
    else
        echo "${response}" | jq '.choices[0].message'
    fi
}

run_candidate() {
    local label="$1" backend="$2" host="$3" port="$4" model="$5"
    port_cleared=0
    echo "########################################"
    echo "# ${label}"
    echo "########################################"

    local messages
    messages="$(jq -n --arg sys "${SYSTEM_PROMPT}" --arg user "${USER_PROMPT}" \
        '[{role:"system",content:$sys},{role:"user",content:$user}]')"

    local step=1 finished=0
    while [[ ${step} -le ${MAX_STEPS} ]]; do
        local response assistant_msg tool_calls_raw content
        response="$(ask "${backend}" "${host}" "${port}" "${model}" "${messages}")"
        assistant_msg="$(extract_message "${response}" "${backend}")"
        content="$(echo "${assistant_msg}" | jq -r '.content // empty')"
        tool_calls_raw="$(echo "${assistant_msg}" | jq -c '.tool_calls // []')"

        if [[ "${tool_calls_raw}" == "[]" ]]; then
            echo "step ${step}: [no tool call] ${content:-<empty>}"
            break
        fi

        # Append the assistant's tool-call message to history (content
        # may be empty/null — normalize to "" so it round-trips cleanly).
        messages="$(echo "${messages}" | jq --argjson m "${assistant_msg}" \
            '. + [{role: "assistant", content: ($m.content // ""), tool_calls: $m.tool_calls}]')"

        local n_calls
        n_calls="$(echo "${tool_calls_raw}" | jq 'length')"
        local i=0
        while [[ ${i} -lt ${n_calls} ]]; do
            local call name args_raw args_json call_id result
            call="$(echo "${tool_calls_raw}" | jq -c ".[${i}]")"
            name="$(echo "${call}" | jq -r '.function.name')"
            call_id="$(echo "${call}" | jq -r '.id // "call_'"${step}_${i}"'"')"
            # llama.cpp/OpenAI: arguments is a JSON-encoded STRING.
            # ollama: arguments is already a JSON object. Normalize both.
            args_raw="$(echo "${call}" | jq -c '.function.arguments')"
            if echo "${args_raw}" | jq -e 'type == "string"' >/dev/null 2>&1; then
                args_json="$(echo "${args_raw}" | jq -r '.' | jq -c '.')"
            else
                args_json="${args_raw}"
            fi

            if [[ "${name}" == "finish_diagnosis" ]]; then
                local root_cause fix resolved
                root_cause="$(echo "${args_json}" | jq -r '.root_cause // empty')"
                fix="$(echo "${args_json}" | jq -r '.fix // empty')"
                resolved="$(echo "${args_json}" | jq -r '.resolved // false')"
                echo "step ${step}: [finish_diagnosis] root_cause=\"${root_cause}\" fix=\"${fix}\" resolved=${resolved}"
                echo "  score: $(score_finish "${root_cause}" "${fix}")"
                finished=1
                break 2
            fi

            local cmd
            cmd="$(echo "${args_json}" | jq -r '.command // empty')"
            result="$(mock_run_command "${cmd}")"
            echo "step ${step}: [tool: ${name}] command=\"${cmd}\""
            echo "  -> ${result}"

            messages="$(echo "${messages}" | jq --arg id "${call_id}" --arg content "${result}" \
                '. + [{role: "tool", tool_call_id: $id, content: $content}]')"
            i=$((i + 1))
        done
        step=$((step + 1))
    done

    if [[ "${finished}" != "1" ]]; then
        echo "  (did not reach finish_diagnosis within ${MAX_STEPS} steps)"
    fi
    echo
}

candidates=("${DEFAULT_CANDIDATES[@]}")
[[ -n "${CANDIDATES:-}" ]] && mapfile -t candidates <<< "${CANDIDATES}"

for candidate in "${candidates[@]}"; do
    IFS='|' read -r label backend host port model <<< "${candidate}"
    run_candidate "${label}" "${backend}" "${host}" "${port}" "${model}"
done
