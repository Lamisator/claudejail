#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
IMAGE_NAME="claude-code-sandbox"
ENV_FILE="${SCRIPT_DIR}/.env"

# `run.sh install [DIR]` symlinks this script as "claudejail" into a
# user-managed PATH directory. A symlink (not a copy) keeps SCRIPT_DIR resolving
# to this repo, so the Dockerfile and .env are still found.
if [[ "${1:-}" == "install" ]]; then
  if [[ $# -gt 2 ]]; then
    echo "usage: $0 install [DIR]" >&2
    exit 1
  fi
  if [[ -n "${2:-}" ]]; then
    INSTALL_DIR="$2"
  else
    # Prefer a user bin dir that is already on PATH; fall back to ~/.local/bin.
    INSTALL_DIR="${HOME}/.local/bin"
    for candidate in "${HOME}/.local/bin" "${HOME}/bin"; do
      if [[ ":${PATH}:" == *":${candidate}:"* ]]; then
        INSTALL_DIR="$candidate"
        break
      fi
    done
  fi
  mkdir -p "$INSTALL_DIR"
  INSTALL_DIR="$(realpath "$INSTALL_DIR")"
  TARGET="${INSTALL_DIR}/claudejail"
  if [[ -e "$TARGET" && ! -L "$TARGET" ]]; then
    echo "error: refusing to overwrite existing non-symlink file: $TARGET" >&2
    exit 1
  fi
  ln -sfn "${SCRIPT_DIR}/$(basename "$(readlink -f "$0")")" "$TARGET"
  echo "installed: $TARGET -> $(readlink "$TARGET")"
  if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
    echo "note: $INSTALL_DIR is not on your PATH; add this to your shell profile:" >&2
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\"" >&2
  fi
  exit 0
fi

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

# If --ssh-key was provided, load it into a private, per-session ssh-agent on
# the host and forward only the agent socket into the container. The key itself
# never enters the container or touches disk unencrypted; the sandbox can ask
# the agent to sign but cannot read or copy the key. The agent is killed when
# this script exits (normal exit, error, or signal).
DOCKER_SSH_ARGS=()
CLAUDE_EXTRA_ARGS=()
if [[ -n "$SSH_KEY" ]]; then
  SSH_KEY="$(realpath "$SSH_KEY")"
  if [[ ! -f "$SSH_KEY" ]]; then
    echo "error: ssh key not found: $SSH_KEY" >&2
    exit 1
  fi
  AGENT_DIR="$(mktemp -d -t claudejail-agent.XXXXXX)"
  AGENT_SOCK="${AGENT_DIR}/agent.sock"
  AGENT_PID=""
  trap '[[ -n "$AGENT_PID" ]] && kill "$AGENT_PID" 2>/dev/null; rm -rf "$AGENT_DIR"' EXIT
  AGENT_PID="$(ssh-agent -a "$AGENT_SOCK" -s | sed -n 's/^SSH_AGENT_PID=\([0-9]*\);.*/\1/p')"
  if [[ -z "$AGENT_PID" ]]; then
    echo "error: failed to start ssh-agent" >&2
    exit 1
  fi
  # ssh-add prompts for the passphrase itself if the key is protected.
  if ! SSH_AUTH_SOCK="$AGENT_SOCK" ssh-add -q "$SSH_KEY" < /dev/tty; then
    echo "error: failed to add ssh key to agent" >&2
    exit 1
  fi

  DOCKER_SSH_ARGS+=(-v "$AGENT_SOCK:/run/ssh-agent.sock" -e SSH_AUTH_SOCK=/run/ssh-agent.sock)
  CLAUDE_EXTRA_ARGS+=(--append-system-prompt "An SSH agent holding the user's key is forwarded into this sandbox (SSH_AUTH_SOCK=/run/ssh-agent.sock). Plain ssh and git commands authenticate through it automatically; no -i or GIT_SSH_COMMAND is needed. The key file itself is not available in the sandbox.")
fi

# Bind-mount host ~/.claude directly — same UID inside and outside means no permission issues
docker run --rm -it \
  ${ANTHROPIC_API_KEY:+-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
  -v "${HOME}/.claude:/home/claude/.claude" \
  -v "${HOME}/.claude.json:/home/claude/.claude.json" \
  -v "$WORKSPACE:/workspace" \
  "${DOCKER_SSH_ARGS[@]+"${DOCKER_SSH_ARGS[@]}"}" \
  "$IMAGE_NAME" \
  "${CLAUDE_EXTRA_ARGS[@]+"${CLAUDE_EXTRA_ARGS[@]}"}" \
  "$@"
