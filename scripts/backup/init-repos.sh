#!/usr/bin/env bash
# Creates the restic password (if missing) and initialises the local and off-site
# repositories. Idempotent; run as the backup user after scripts/backup/install.sh.
#
#   scripts/backup/init-repos.sh
#
# Whichever repository is created second takes the chunker parameters of the other, so
# that `restic copy` deduplicates between both (after a disaster recovery, the new local
# repository follows the surviving off-site one).
SCRIPT_NAME=init-repos

# shellcheck source=scripts/backup/lib.sh
. "$(dirname "$0")/lib.sh"

if [ ! -s "$RESTIC_PASSWORD_FILE" ]; then
  mkdir -p "$(dirname "$RESTIC_PASSWORD_FILE")"
  openssl rand -base64 48 >"$RESTIC_PASSWORD_FILE"
  log "generated $RESTIC_PASSWORD_FILE"
  log "!!! store its content in the password manager NOW: without it the backups are unreadable !!!"
fi

mkdir -p "$BACKUP_ROOT/work" "$RESTIC_CACHE_DIR"
if restic_local cat config >/dev/null 2>&1; then
  log "local repository $RESTIC_LOCAL_REPOSITORY already initialised"
elif [ -n "$RESTIC_OFFSITE_REPOSITORY" ] && restic_offsite cat config >/dev/null 2>&1; then
  restic_local init --repository-version 2 --copy-chunker-params \
    --from-repo "$RESTIC_OFFSITE_REPOSITORY" --from-password-file "$RESTIC_PASSWORD_FILE"
else
  restic_local init --repository-version 2
fi

if [ -z "$RESTIC_OFFSITE_REPOSITORY" ]; then
  log "RESTIC_OFFSITE_REPOSITORY not set, skipping the off-site repository"
elif restic_offsite cat config >/dev/null 2>&1; then
  log "off-site repository $RESTIC_OFFSITE_REPOSITORY already initialised"
else
  restic_offsite init --repository-version 2 --copy-chunker-params \
    --from-repo "$RESTIC_LOCAL_REPOSITORY" --from-password-file "$RESTIC_PASSWORD_FILE"
fi
