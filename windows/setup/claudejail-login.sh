#!/usr/bin/env bash
# Started by the Windows launcher ("Sign in to Claude"). Runs Claude Code once
# inside the claudejail WSL environment so the login lands in ~/.claude, which
# claudejail mounts into the sandbox.
if command -v wslview >/dev/null 2>&1; then
  export BROWSER=wslview
fi
cat <<'EOF'
Sign in to Claude
-----------------
Claude Code starts below. Choose a theme, then log in with your Claude
account. A browser window opens; if it doesn't, Ctrl+click the link.
When Claude's prompt appears, type /exit to close this window.

EOF
"$HOME/.local/bin/claude"
rc=$?
if [[ $rc -ne 0 ]]; then
  echo
  read -rp "Claude Code exited with code $rc. Press Enter to close this window. " _
fi
