#!/usr/bin/env bash
# Builds the claudejail Docker image for the current user, the same way run.sh
# does. Pass "update" to also pull the newest Claude Code release.
set -euo pipefail
exec 2>&1

echo "--> Waiting for Docker to start"
for _ in $(seq 1 45); do
  if docker info >/dev/null 2>&1; then
    break
  fi
  sudo systemctl start docker >/dev/null 2>&1 || true
  sleep 2
done
if ! docker info >/dev/null 2>&1; then
  echo "error: Docker is not running."
  docker info || true
  exit 1
fi

cd "$HOME/claudejail"
args=(--progress=plain --build-arg "USER_UID=$(id -u)" -t claude-code-sandbox)
if [[ "${1:-}" == "update" ]]; then
  args+=(--build-arg "CLAUDE_CACHE_BUST=$(date +%s)")
fi
echo "--> Building the claudejail image"
docker build "${args[@]}" .
echo "--> Image ready"
