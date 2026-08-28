#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
IMAGE_NAME="claude-code-sandbox"
ENV_FILE="${SCRIPT_DIR}/.env"

# Extract --rebuild and --ssh-key from args without disturbing order of remaining args
REBUILD=false
SSH_KEY=""
FILTERED=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild)
      REBUILD=true
      shift
      ;;
    --ssh-key)
      if [[ $# -lt 2 ]]; then
        echo "error: --ssh-key requires a path argument" >&2
        exit 1
      fi
      SSH_KEY="$2"
      shift 2
      ;;
    --ssh-key=*)
      SSH_KEY="${1#--ssh-key=}"
      shift
      ;;
    *)
      FILTERED+=("$1")
      shift
      ;;
  esac
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

# If --ssh-key was provided, copy it ephemerally into the workspace root and
# ensure it is removed when this script exits (normal exit, error, or signal).
EPHEMERAL_KEY=""
CLAUDE_EXTRA_ARGS=()
if [[ -n "$SSH_KEY" ]]; then
  SSH_KEY="$(realpath "$SSH_KEY")"
  if [[ ! -f "$SSH_KEY" ]]; then
    echo "error: ssh key not found: $SSH_KEY" >&2
    exit 1
  fi
  EPHEMERAL_KEY="${WORKSPACE}/$(basename "$SSH_KEY")"
  if [[ -e "$EPHEMERAL_KEY" ]]; then
    echo "error: refusing to overwrite existing file in workspace: $EPHEMERAL_KEY" >&2
    exit 1
  fi
  install -m 600 "$SSH_KEY" "$EPHEMERAL_KEY"
  trap 'rm -f "$EPHEMERAL_KEY"' EXIT
  CLAUDE_EXTRA_ARGS+=(--append-system-prompt "An ephemeral SSH private key is available at /workspace/$(basename "$SSH_KEY") (mode 0600). Use it for git/ssh operations that require authentication (e.g. via GIT_SSH_COMMAND='ssh -i /workspace/$(basename "$SSH_KEY")' or ssh -i). The file is deleted when this session ends.")
fi

# Bind-mount host ~/.claude directly — same UID inside and outside means no permission issues
docker run --rm -it \
  ${ANTHROPIC_API_KEY:+-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
  -v "${HOME}/.claude:/home/claude/.claude" \
  -v "${HOME}/.claude.json:/home/claude/.claude.json" \
  -v "$WORKSPACE:/workspace" \
  "$IMAGE_NAME" \
  "${CLAUDE_EXTRA_ARGS[@]+"${CLAUDE_EXTRA_ARGS[@]}"}" \
  "$@"
