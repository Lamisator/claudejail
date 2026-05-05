#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
IMAGE_NAME="claude-code-sandbox"
ENV_FILE="${SCRIPT_DIR}/.env"

# Extract --rebuild from args without disturbing order of remaining args
REBUILD=false
FILTERED=()
for arg in "$@"; do
  if [[ "$arg" == "--rebuild" ]]; then
    REBUILD=true
  else
    FILTERED+=("$arg")
  fi
done
set -- "${FILTERED[@]+"${FILTERED[@]}"}"

# First positional arg (if it doesn't start with --) is the workspace path;
# everything else is forwarded to claude.
if [[ $# -gt 0 && "$1" != --* ]]; then
  WORKSPACE="$(realpath "$1")"
  shift
else
  WORKSPACE="$(realpath "${PWD}")"
fi

# Load API key from .env if present (optional — Claude Max uses host OAuth credentials)
if [[ -z "${ANTHROPIC_API_KEY:-}" && -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

if $REBUILD || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  docker build --build-arg USER_UID="$(id -u)" -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

# Bind-mount host ~/.claude directly — same UID inside and outside means no permission issues
docker run --rm -it \
  ${ANTHROPIC_API_KEY:+-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
  -v "${HOME}/.claude:/home/claude/.claude" \
  -v "${HOME}/.claude.json:/home/claude/.claude.json" \
  -v "$WORKSPACE:/workspace" \
  "$IMAGE_NAME" \
  "$@"
