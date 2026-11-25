# claudejail on Windows

`Install-claudejail.cmd` is a graphical installer. Download that one file and
double-click it; it fetches the setup wizard from this repository on GitHub and
the wizard does the rest. No console input is needed.

## What the wizard does

1. Checks Windows (64-bit, build 19041 or newer), hardware virtualization and
   free disk space.
2. Installs WSL 2 if it is missing. Windows asks for administrator permission
   once, and may need a restart; setup reopens by itself after you sign in again.
3. Asks for a few settings: Linux user name, Claude account or API key, an
   optional SSH key from `%USERPROFILE%\.ssh`, and which shortcuts to add.
4. Imports a separate WSL distribution called `claudejail` (Ubuntu 24.04 from
   Microsoft's distribution list, SHA-256 checked). Other WSL distributions are
   not touched.
5. Inside it: creates the user, turns on systemd, installs Docker Engine,
   clones this repository to `~/claudejail`, installs Claude Code (for signing
   in), and builds the `claude-code-sandbox` image.
6. Adds Start menu entries, an "Open in claudejail" entry to the folder
   right-click menu, and an entry in Settings > Apps for uninstalling.
7. With a Claude account: opens a terminal once so you can sign in.

## Using it

- Right-click a folder in Explorer and choose **Open in claudejail** (Windows 11:
  under *Show more options*), or start **claudejail** from the Start menu and
  pick a folder. Claude Code opens in Windows Terminal (or a console window if
  Windows Terminal isn't installed).
- **claudejail projects** in the Start menu opens `~/projects` inside the
  environment. Projects there are much faster than projects on `C:`.
- **claudejail setup (update or repair)** pulls the latest claudejail from
  GitHub, re-runs the setup steps and rebuilds the image with the newest
  Claude Code. Your files are kept.
- **Uninstall claudejail** removes the environment (including everything in
  it), shortcuts and menu entries. WSL itself stays installed.

## Files

| File | Where it runs | Purpose |
|------|---------------|---------|
| `Install-claudejail.cmd` | Windows | Downloads and starts the wizard |
| `setup/ClaudeJailSetup.ps1` | Windows | The wizard; also update and uninstall |
| `setup/Launch-ClaudeJail.ps1` | Windows | Opens a folder in claudejail in a terminal |
| `setup/provision.sh` | WSL, as root | Sets up user, systemd, Docker, the repo clone |
| `setup/build-image.sh` | WSL | Builds the image like `run.sh` does |
| `setup/claudejail-session.sh` | WSL | Runs `claudejail`; keeps the window open on errors |
| `setup/claudejail-login.sh` | WSL | Runs Claude Code once to sign in |

Installed files live in `%LOCALAPPDATA%\claudejail` (`app` for scripts and
`config.json`, `distro` for the WSL disk, `setup.log` for the setup log).

## Testing a branch

The installer uses the `main` branch. To install from another branch, set
`CLAUDEJAIL_REF` before starting the `.cmd`, for example in the Run dialog:

```
cmd /c "set CLAUDEJAIL_REF=my-branch&& path\to\Install-claudejail.cmd"
```

The chosen branch is remembered for later updates.

## Security notes

The `claudejail` Linux user has passwordless `sudo`; it is also in the `docker`
group, which is root-equivalent, so a password would not add protection. The
sandbox itself is unchanged: Claude runs with `--dangerously-skip-permissions`
and can change anything in the project folder it was opened on, reads and
writes your Claude sign-in in `~/.claude`, and has network access.
