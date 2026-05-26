#!/usr/bin/env bash
# Shared env loader — source this at the top of each deploy script.
# Loads .env from repo root. Validation of required vars is each script's responsibility.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi