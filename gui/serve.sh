#!/usr/bin/env bash
# Serve the workout GUI over localhost HTTP so the ollama candidates work.
#
# Why a server at all: opening dashboard.html as a file:// URL is fine for
# llama.cpp (:8080 returns Access-Control-Allow-Origin: null), but ollama
# (:11434) refuses a null origin with 403. ollama *does* allow any
# http://localhost origin, so serving the page from localhost fixes it with no
# OLLAMA_ORIGINS / service change. See README "The workout GUI".
#
#   gui/serve.sh                 # serve on 127.0.0.1:8000, print the URL
#   GUI_PORT=9000 gui/serve.sh   # pick the port
#
# Bound to 127.0.0.1 on purpose (this box is remote). To reach it from your
# laptop, tunnel the port instead of exposing it:
#   ssh -L 8000:127.0.0.1:8000 huey@<box>    then open the URL locally.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="127.0.0.1"
PORT="${GUI_PORT:-8000}"
URL="http://${HOST}:${PORT}/gui/dashboard.html"

if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL: python3 not found (needed for the static file server)" >&2
    exit 1
fi

echo "== Inky's Gym GUI =="
echo "serving ${REPO_DIR} at ${URL}"
echo "remote box? tunnel first:  ssh -L ${PORT}:${HOST}:${PORT} huey@<box>"
echo "Ctrl-C to stop."
echo

# --directory keeps the CWD clean; --bind pins it to loopback.
exec python3 -m http.server "${PORT}" --bind "${HOST}" --directory "${REPO_DIR}"
