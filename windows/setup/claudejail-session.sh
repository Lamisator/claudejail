#!/usr/bin/env bash
# Started by the Windows launcher in a terminal window. Runs claudejail and,
# if it fails, keeps the window open so the error can be read.
claudejail "$@"
rc=$?
if [[ $rc -ne 0 ]]; then
  echo
  read -rp "claudejail exited with code $rc. Press Enter to close this window. " _
fi
exit "$rc"
