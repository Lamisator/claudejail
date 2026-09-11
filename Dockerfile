FROM node:lts-bookworm

RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    sudo \
    unzip \
    jq \
    ripgrep \
    && rm -rf /var/lib/apt/lists/*

ARG CLAUDE_CACHE_BUST=0
RUN echo "cache-bust: $CLAUDE_CACHE_BUST" && npm install -g @anthropic-ai/claude-code

RUN pip3 config set global.break-system-packages true 2>/dev/null || true

# Create the claude user with the same UID as the host user so bind-mounted
# ~/.claude files are readable/writable without permission errors.
# The base image already has a 'node' user at UID 1000 — rename it if needed.
ARG USER_UID=1000
RUN existing=$(getent passwd "$USER_UID" | cut -d: -f1 || true); \
    if [ -n "$existing" ]; then \
      usermod -l claude -d /home/claude -m "$existing"; \
      groupmod -n claude "$existing" 2>/dev/null || true; \
    else \
      useradd -m -u "$USER_UID" -s /bin/bash claude; \
    fi \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude

USER claude
WORKDIR /workspace

ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
