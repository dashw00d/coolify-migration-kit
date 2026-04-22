#!/usr/bin/env bash
# provision-host.sh
#
# Idempotent VPS host setup for the Coolify migration kit.
# Creates a dedicated client user, shared apps directory, installs the
# SSH public key, and sets a landing cwd. Run as root on the VPS.
#
# Usage:
#   CLIENT_NAME=yourclient CLIENT_UID=1000 \
#     SSH_PUBKEY="ssh-ed25519 AAAA... you@laptop" \
#     sudo -E ./provision-host.sh
#
# Subsequent clients on the same VPS:
#   CLIENT_NAME=client2 CLIENT_UID=1001 SSH_PUBKEY="..." sudo -E ./provision-host.sh
#
# The script is safe to re-run — every step checks current state first.

set -euo pipefail

CLIENT_NAME="${CLIENT_NAME:?set CLIENT_NAME (e.g. acme)}"
CLIENT_UID="${CLIENT_UID:-1000}"
APPS_DIR="${APPS_DIR:-/opt/${CLIENT_NAME}-apps}"
SSH_PUBKEY="${SSH_PUBKEY:?set SSH_PUBKEY to the public key string you want installed for SSH/SFTP access}"

# If true, add the client user to the docker group so they can run
# `docker exec` without sudo (needed for the per-app artisan wrappers).
# Note: docker group access is root-equivalent. Leave false for a setup
# where the client user is separate from the ops user.
ADD_TO_DOCKER_GROUP="${ADD_TO_DOCKER_GROUP:-true}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

log "Client: ${CLIENT_NAME}, UID: ${CLIENT_UID}, Apps dir: ${APPS_DIR}"

# --- 1. User + group ---------------------------------------------------------
if id "$CLIENT_NAME" &>/dev/null; then
  existing_uid=$(id -u "$CLIENT_NAME")
  if [[ "$existing_uid" != "$CLIENT_UID" ]]; then
    warn "User ${CLIENT_NAME} exists with uid=${existing_uid}, expected ${CLIENT_UID}."
    warn "Container www-data must match this uid. Update Dockerfile or recreate the user."
  else
    log "User ${CLIENT_NAME} already exists with correct uid=${CLIENT_UID}."
  fi
else
  log "Creating user ${CLIENT_NAME} with uid=${CLIENT_UID}."
  # -U creates a group of the same name.
  useradd -m -s /bin/bash -u "$CLIENT_UID" -U "$CLIENT_NAME"
fi

# --- 2. Shared apps directory ------------------------------------------------
if [[ -d "$APPS_DIR" ]]; then
  log "${APPS_DIR} already exists."
else
  log "Creating ${APPS_DIR}."
  mkdir -p "$APPS_DIR"
fi
chown "${CLIENT_NAME}:${CLIENT_NAME}" "$APPS_DIR"
# setgid so new files/dirs inherit the group (keeps perms sane under SFTP drops)
chmod 2775 "$APPS_DIR"

# --- 3. SSH key --------------------------------------------------------------
HOME_DIR="/home/${CLIENT_NAME}"
SSH_DIR="${HOME_DIR}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

install -d -m 700 -o "$CLIENT_NAME" -g "$CLIENT_NAME" "$SSH_DIR"

if [[ -f "$AUTH_KEYS" ]] && grep -qxF "$SSH_PUBKEY" "$AUTH_KEYS"; then
  log "SSH public key already present in authorized_keys."
else
  log "Installing SSH public key."
  printf '%s\n' "$SSH_PUBKEY" >> "$AUTH_KEYS"
fi
chmod 600 "$AUTH_KEYS"
chown "${CLIENT_NAME}:${CLIENT_NAME}" "$AUTH_KEYS"

# --- 4. Docker group membership (optional) -----------------------------------
if [[ "$ADD_TO_DOCKER_GROUP" == "true" ]]; then
  if getent group docker >/dev/null 2>&1; then
    if id -nG "$CLIENT_NAME" | tr ' ' '\n' | grep -qx docker; then
      log "${CLIENT_NAME} already in docker group."
    else
      log "Adding ${CLIENT_NAME} to docker group (root-equivalent access)."
      usermod -aG docker "$CLIENT_NAME"
      warn "Active SSH sessions for ${CLIENT_NAME} must log out and back in for this to take effect."
    fi
  else
    warn "docker group not found. Is Docker installed? Skipping."
  fi
else
  log "Skipping docker group membership (ADD_TO_DOCKER_GROUP=false)."
fi

# --- 5. Landing cwd on interactive shell -------------------------------------
BASHRC="${HOME_DIR}/.bashrc"
LANDING_LINE="cd ${APPS_DIR}"

touch "$BASHRC"
chown "${CLIENT_NAME}:${CLIENT_NAME}" "$BASHRC"
if grep -qxF "$LANDING_LINE" "$BASHRC"; then
  log "Landing cwd already configured in .bashrc."
else
  log "Adding landing cwd to .bashrc."
  printf '\n# Auto-added by provision-host.sh: land in apps dir on login\n%s\n' "$LANDING_LINE" >> "$BASHRC"
fi

# --- 5. Verify ---------------------------------------------------------------
log "Verification:"
id "$CLIENT_NAME"
ls -ld "$APPS_DIR"
ls -la "$SSH_DIR"

log "Done. Test with:  ssh ${CLIENT_NAME}@<this-host>"
log "You should land in: ${APPS_DIR}"
