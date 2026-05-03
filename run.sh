#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
IMAGE_NAME="claude-code-sandbox"
ENV_FILE="${SCRIPT_DIR}/.env"

# First positional arg (if it doesn't start with --) is the workspace path;
# everything else is forwarded to claude.
WORKSPACE="${SCRIPT_DIR}/workspace"
if [[ $# -gt 0 && "$1" != --* ]]; then
  WORKSPACE="$1"
  shift
fi

# Load API key from .env if present (optional — Claude Max uses host OAuth credentials)
if [[ -z "${ANTHROPIC_API_KEY:-}" && -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# Always rebuild so USER_UID stays in sync with the current host user
docker build --build-arg USER_UID="$(id -u)" -t "$IMAGE_NAME" "$SCRIPT_DIR"

mkdir -p "$WORKSPACE"

# Bind-mount host ~/.claude directly — same UID inside and outside means no permission issues
docker run --rm -it \
  ${ANTHROPIC_API_KEY:+-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
  -v "${HOME}/.claude:/home/claude/.claude" \
  -v "${HOME}/.claude.json:/home/claude/.claude.json" \
  -v "$(realpath "$WORKSPACE"):/workspace" \
  "$IMAGE_NAME" \
  "$@"
