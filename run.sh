#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
IMAGE_NAME="claude-code-sandbox"
ENV_FILE="${SCRIPT_DIR}/.env"

# Extract --rebuild, --update and --ssh-key from args without disturbing order of remaining args
REBUILD=false
UPDATE=false
SSH_KEY=""
FILTERED=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild)
      REBUILD=true
      shift
      ;;
    --update)
      UPDATE=true
      shift
      ;;
    --ssh-key|-i)
      if [[ $# -lt 2 ]]; then
        echo "error: $1 requires a path argument" >&2
        exit 1
      fi
      SSH_KEY="$2"
      shift 2
      ;;
    --ssh-key=*)
      SSH_KEY="${1#--ssh-key=}"
      shift
      ;;
    -i=*)
      SSH_KEY="${1#-i=}"
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

if $UPDATE || $REBUILD || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  BUILD_ARGS=(--build-arg USER_UID="$(id -u)")
  if $UPDATE; then
    BUILD_ARGS+=(--build-arg CLAUDE_CACHE_BUST="$(date +%s)")
  fi
  docker build "${BUILD_ARGS[@]}" -t "$IMAGE_NAME" "$SCRIPT_DIR"
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
  # ssh-keygen -p may leave a "<file>.old" backup — clean both.
  trap 'rm -f "$EPHEMERAL_KEY" "$EPHEMERAL_KEY.old"' EXIT

  # If the ephemeral key is passphrase-protected, prompt for it (up to 3 tries)
  # and strip the passphrase in place so ssh/git can use the key non-interactively
  # inside the sandbox.
  if ! ssh-keygen -y -P "" -f "$EPHEMERAL_KEY" >/dev/null 2>&1; then
    echo "ssh key is passphrase-protected; unlocking ephemeral copy" >&2
    unlocked=false
    for _ in 1 2 3; do
      read -rsp "Passphrase for $SSH_KEY: " KEY_PASSPHRASE < /dev/tty
      echo
      if ssh-keygen -p -P "$KEY_PASSPHRASE" -N "" -f "$EPHEMERAL_KEY" >/dev/null 2>&1; then
        unset KEY_PASSPHRASE
        unlocked=true
        break
      fi
      unset KEY_PASSPHRASE
      echo "incorrect passphrase" >&2
    done
    if ! $unlocked; then
      echo "error: failed to unlock ssh key after 3 attempts" >&2
      exit 1
    fi
  fi

  CLAUDE_EXTRA_ARGS+=(--append-system-prompt "An ephemeral SSH private key is available at /workspace/$(basename "$SSH_KEY") (mode 0600, no passphrase). Use it for git/ssh operations that require authentication (e.g. via GIT_SSH_COMMAND='ssh -i /workspace/$(basename "$SSH_KEY")' or ssh -i). The file is deleted when this session ends.")
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
