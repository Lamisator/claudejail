#!/usr/bin/env bash
# Provisions the "claudejail" WSL distribution. The Windows setup wizard runs
# this as root (wsl.exe -u root) and passes:
#   CJ_USER  Linux user to create (UID 1000 if free)
#   CJ_REPO  GitHub repository to clone, e.g. lamisator/claudejail
#   CJ_REF   branch to check out, e.g. main
# Safe to run again: every step checks what is already there.
set -euo pipefail
exec 2>&1
export DEBIAN_FRONTEND=noninteractive

CJ_USER="${CJ_USER:?CJ_USER must be set}"
CJ_REPO="${CJ_REPO:-lamisator/claudejail}"
CJ_REF="${CJ_REF:-main}"

if [[ ! "$CJ_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "error: invalid user name: $CJ_USER" >&2
  exit 1
fi
if [[ ! "$CJ_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "error: invalid repository: $CJ_REPO" >&2
  exit 1
fi
if [[ ! "$CJ_REF" =~ ^[A-Za-z0-9_./-]+$ ]]; then
  echo "error: invalid branch: $CJ_REF" >&2
  exit 1
fi

cd /
say() { printf '\n--> %s\n' "$*"; }
as_user() { sudo -u "$CJ_USER" -H "$@"; }

say "Linux user: $CJ_USER"
if ! id "$CJ_USER" >/dev/null 2>&1; then
  if getent passwd 1000 >/dev/null; then
    useradd --create-home --shell /bin/bash "$CJ_USER"
  else
    useradd --create-home --shell /bin/bash --uid 1000 "$CJ_USER"
  fi
fi
usermod -aG sudo "$CJ_USER"
# No password: membership in the docker group is root-equivalent anyway, and
# the Windows user can always get a root shell with "wsl -d claudejail -u root".
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$CJ_USER" > /etc/sudoers.d/90-claudejail
chmod 0440 /etc/sudoers.d/90-claudejail
HOME_DIR="$(getent passwd "$CJ_USER" | cut -d: -f6)"

say "WSL settings (systemd, default user)"
cat > /etc/wsl.conf <<EOF
[boot]
systemd=true

[user]
default=$CJ_USER
EOF

say "Base packages"
apt-get update
apt-get install -y ca-certificates curl git openssh-client sudo
# wslu provides wslview, which lets Linux programs open links in the Windows browser.
apt-get install -y wslu || echo "note: wslu is not available; open sign-in links by hand"

say "Docker Engine"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
fi
usermod -aG docker "$CJ_USER"
systemctl enable docker.service containerd.service >/dev/null 2>&1 || true

say "claudejail ($CJ_REPO, branch $CJ_REF)"
APP="$HOME_DIR/claudejail"
URL="https://github.com/$CJ_REPO.git"
if [[ -d "$APP/.git" ]]; then
  as_user git -C "$APP" fetch origin "+refs/heads/$CJ_REF:refs/remotes/origin/$CJ_REF"
  if [[ "$(as_user git -C "$APP" rev-parse --abbrev-ref HEAD)" == "$CJ_REF" ]]; then
    as_user git -C "$APP" merge --ff-only "origin/$CJ_REF" \
      || echo "warning: local changes in $APP keep it from updating; leaving it as it is"
  else
    as_user git -C "$APP" checkout -B "$CJ_REF" "origin/$CJ_REF"
  fi
else
  if [[ -e "$APP" ]]; then
    mv "$APP" "$APP.old.$(date +%s)"
  fi
  as_user git clone --branch "$CJ_REF" "$URL" "$APP"
fi

install -d -o "$CJ_USER" -g "$CJ_USER" "$HOME_DIR/projects" "$HOME_DIR/.claude"
install -d -m 700 -o "$CJ_USER" -g "$CJ_USER" "$HOME_DIR/.ssh"
# Docker creates a directory if a bind-mounted file is missing; repair that.
if [[ -d "$HOME_DIR/.claude.json" ]]; then
  rm -rf "$HOME_DIR/.claude.json"
fi
if [[ ! -e "$HOME_DIR/.claude.json" ]]; then
  echo '{}' > "$HOME_DIR/.claude.json"
  chown "$CJ_USER:$CJ_USER" "$HOME_DIR/.claude.json"
fi

ln -sfn "$APP/run.sh" /usr/local/bin/claudejail
ln -sfn "$APP/windows/setup/claudejail-session.sh" /usr/local/bin/claudejail-session
ln -sfn "$APP/windows/setup/claudejail-login.sh" /usr/local/bin/claudejail-login
chmod 755 "$APP/run.sh" "$APP"/windows/setup/*.sh

say "Claude Code (used to sign in)"
if [[ ! -x "$HOME_DIR/.local/bin/claude" ]]; then
  as_user bash -c 'curl -fsSL https://claude.ai/install.sh | bash' \
    || echo "warning: Claude Code could not be installed; signing in with an account will not work"
fi

say "Provisioning finished"
