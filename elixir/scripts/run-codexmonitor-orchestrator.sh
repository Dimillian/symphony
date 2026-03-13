#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELIXIR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORKFLOW_FILE="${ELIXIR_DIR}/WORKFLOW.codexmonitor.md"
LOG_ROOT="${ELIXIR_DIR}/log/codexmonitor"
PORT="4111"
ACK_FLAG="--i-understand-that-this-will-be-running-without-the-usual-guardrails"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_file() {
  if [ ! -f "$1" ]; then
    echo "Missing required file: $1" >&2
    exit 1
  fi
}

require_command codex
require_command mise

shell_linear_api_key="${LINEAR_API_KEY:-}"
eval "$(mise env -s bash)"

launchctl_linear_api_key=""
if command -v launchctl >/dev/null 2>&1; then
  launchctl_linear_api_key="$(launchctl getenv LINEAR_API_KEY || true)"
fi

if [ -n "${launchctl_linear_api_key}" ]; then
  export LINEAR_API_KEY="${launchctl_linear_api_key}"
elif [ -n "${shell_linear_api_key}" ]; then
  export LINEAR_API_KEY="${shell_linear_api_key}"
fi

if [ -z "${LINEAR_API_KEY:-}" ]; then
  echo "LINEAR_API_KEY is missing" >&2
  exit 1
fi

require_file "${WORKFLOW_FILE}"
require_file "${ELIXIR_DIR}/mix.exs"
require_file "${ELIXIR_DIR}/bin/symphony"

mkdir -p "${LOG_ROOT}"
cd "${ELIXIR_DIR}"

exec ./bin/symphony \
  "${ACK_FLAG}" \
  --logs-root "${LOG_ROOT}" \
  --port "${PORT}" \
  "${WORKFLOW_FILE}"
