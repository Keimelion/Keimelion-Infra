#!/usr/bin/env bash
# One-time system setup of the backups (root): restic package, backup directory, systemd
# units + timers, and the sudoers rule letting the GitHub runner take the pre-deploy backups
# and restore the API's one on a rollback.
# Idempotent: rerun it after changing systemd/ (units are copied, not linked, so a commit
# cannot change what root runs without this script).
# Each stack has its own units and sudoers file, named after BACKUP_UNIT_PREFIX in its .env
# (default keimelion), and refuses to replace those of another checkout.
#
#   sudo scripts/backup/install.sh [backup-user]   (default: $SUDO_USER)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
BACKUP_USER=${1:-${SUDO_USER:?pass the backup user}}
RUNNER_USER=${RUNNER_USER:-github-runner}
INFRA_DIR=$(cd "$(dirname "$0")/../.." && pwd)
env_value() { sed -n "s/^$1=//p" "$INFRA_DIR/.env" | tail -n 1; }
BACKUP_ROOT=$(env_value BACKUP_ROOT)
BACKUP_ROOT=${BACKUP_ROOT:-/var/backups/keimelion}
UNIT_PREFIX=$(env_value BACKUP_UNIT_PREFIX)
UNIT_PREFIX=${UNIT_PREFIX:-keimelion}
BACKUP_ON_CALENDAR=$(env_value BACKUP_ON_CALENDAR)
BACKUP_ON_CALENDAR=${BACKUP_ON_CALENDAR:-*-*-* 00/6:15:00}
VERIFY_ON_CALENDAR=$(env_value VERIFY_ON_CALENDAR)
VERIFY_ON_CALENDAR=${VERIFY_ON_CALENDAR:-Sun *-*-* 04:45:00}

existing=/etc/systemd/system/$UNIT_PREFIX-db-backup@.service
if [ -f "$existing" ] && ! grep -q "^ExecStart=$INFRA_DIR/" "$existing"; then
  echo "$existing belongs to another checkout: set BACKUP_UNIT_PREFIX in $INFRA_DIR/.env" >&2
  exit 1
fi

id -nG "$BACKUP_USER" | grep -qw docker || { echo "$BACKUP_USER must be in the docker group" >&2; exit 1; }

command -v restic >/dev/null || { apt-get update -q && apt-get install -y -q restic; }
restic version

install -d -m 0700 -o "$BACKUP_USER" -g "$BACKUP_USER" "$BACKUP_ROOT"

for unit in "$INFRA_DIR"/systemd/*.service "$INFRA_DIR"/systemd/*.timer; do
  target=/etc/systemd/system/$UNIT_PREFIX-$(basename "$unit" | sed 's/^keimelion-//')
  sed -e "s|@BACKUP_USER@|$BACKUP_USER|g" -e "s|@INFRA_DIR@|$INFRA_DIR|g" -e "s|@UNIT_PREFIX@|$UNIT_PREFIX|g" \
    -e "s|@BACKUP_ON_CALENDAR@|$BACKUP_ON_CALENDAR|g" -e "s|@VERIFY_ON_CALENDAR@|$VERIFY_ON_CALENDAR|g" "$unit" >"$target"
  chmod 0644 "$target"
done

# Exact commands only (no wildcard: `systemctl start` accepts several units). Used by
# deploy-infra.yml (@pre-deploy) and deploy.yml (@pre-deploy-api, restore on rollback).
if id "$RUNNER_USER" >/dev/null 2>&1; then
  sudoers=$(mktemp)
  for unit in "$UNIT_PREFIX-db-backup@pre-deploy" "$UNIT_PREFIX-db-backup@pre-deploy-api" "$UNIT_PREFIX-db-restore@pre-deploy-api"; do
    echo "$RUNNER_USER ALL=(root) NOPASSWD: /usr/bin/systemctl start --wait $unit.service"
  done >"$sudoers"
  visudo -cqf "$sudoers"
  install -m 0440 "$sudoers" "/etc/sudoers.d/$UNIT_PREFIX-backup"
  rm -f "$sudoers"
fi

systemctl daemon-reload
systemctl enable --now "$UNIT_PREFIX-db-backup.timer" "$UNIT_PREFIX-backup-verify.timer"
systemctl list-timers 'keimelion-*'
echo
echo "Next: as $BACKUP_USER, run scripts/backup/init-repos.sh, then a first backup:"
echo "  sudo systemctl start --wait $UNIT_PREFIX-db-backup@manual.service && journalctl -u $UNIT_PREFIX-db-backup@manual -n 30"
