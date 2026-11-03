#!/usr/bin/env bash
# One-time system setup of the backups (root): restic package, backup directory, systemd
# units + timers, and the sudoers rule letting the GitHub runner take the pre-deploy backup.
# Idempotent: rerun it after changing systemd/ (units are copied, not linked, so a commit
# cannot change what root runs without this script).
#
#   sudo scripts/backup/install.sh [backup-user]   (default: $SUDO_USER)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
BACKUP_USER=${1:-${SUDO_USER:?pass the backup user}}
RUNNER_USER=${RUNNER_USER:-github-runner}
INFRA_DIR=$(cd "$(dirname "$0")/../.." && pwd)
BACKUP_ROOT=$(sed -n 's/^BACKUP_ROOT=//p' "$INFRA_DIR/.env" | tail -n 1)
BACKUP_ROOT=${BACKUP_ROOT:-/var/backups/keimelion}

id -nG "$BACKUP_USER" | grep -qw docker || { echo "$BACKUP_USER must be in the docker group" >&2; exit 1; }

command -v restic >/dev/null || { apt-get update -q && apt-get install -y -q restic; }
restic version

install -d -m 0700 -o "$BACKUP_USER" -g "$BACKUP_USER" "$BACKUP_ROOT"

for unit in "$INFRA_DIR"/systemd/*.service "$INFRA_DIR"/systemd/*.timer; do
  sed -e "s|@BACKUP_USER@|$BACKUP_USER|g" -e "s|@INFRA_DIR@|$INFRA_DIR|g" "$unit" \
    >"/etc/systemd/system/$(basename "$unit")"
  chmod 0644 "/etc/systemd/system/$(basename "$unit")"
done

# The deploy workflow runs `sudo -n systemctl start --wait keimelion-db-backup@pre-deploy.service`.
if id "$RUNNER_USER" >/dev/null 2>&1; then
  sudoers=$(mktemp)
  echo "$RUNNER_USER ALL=(root) NOPASSWD: /usr/bin/systemctl start --wait keimelion-db-backup@pre-deploy.service" >"$sudoers"
  visudo -cqf "$sudoers"
  install -m 0440 "$sudoers" /etc/sudoers.d/keimelion-backup
  rm -f "$sudoers"
fi

systemctl daemon-reload
systemctl enable --now keimelion-db-backup.timer keimelion-backup-verify.timer
systemctl list-timers 'keimelion-*'
echo
echo "Next: as $BACKUP_USER, run scripts/backup/init-repos.sh, then a first backup:"
echo "  sudo systemctl start --wait keimelion-db-backup@manual.service && journalctl -u keimelion-db-backup@manual -n 30"
