#!/usr/bin/env bash
# Backs up the Keimelion data into the restic repositories: consistent Postgres dump, roles,
# per-table row counts (taken in the dump's own snapshot, checked by backup-verify.sh),
# data/uploads and .env. Then applies retention and copies the snapshot off-site.
#
#   scripts/backup/db-backup.sh [scheduled|pre-deploy[-<name>]|pre-restore|manual]   (default: manual)
#
# pre-deploy-<name> (e.g. pre-deploy-api, taken by deploy.yml) is tagged pre-deploy + <name>
# and records its snapshot ID in $BACKUP_ROOT/last-pre-deploy-<name>: that exact snapshot
# is what `db-restore.sh --last pre-deploy-<name>` restores when a deploy is rolled back.
#
# "scheduled" runs from keimelion-db-backup.timer and pings HC_BACKUP_URL; an off-site
# failure fails the run. For the other tags the off-site copy is best effort: a deploy
# must not be blocked by the NAS being down, the local snapshot is what a rollback needs.
SCRIPT_NAME=db-backup
TAG=${1:-manual}
LABEL=""
case "$TAG" in
  scheduled | pre-deploy | pre-restore | manual) ;;
  pre-deploy-*)
    LABEL=${TAG#pre-deploy-}
    TAG=pre-deploy
    [[ "$LABEL" =~ ^[a-z0-9]+$ ]] || { echo "invalid label '$LABEL'" >&2; exit 2; } ;;
  *) echo "usage: $0 [scheduled|pre-deploy[-<name>]|pre-restore|manual]" >&2; exit 2 ;;
esac

# shellcheck source=scripts/backup/lib.sh
. "$(dirname "$0")/lib.sh"

mkdir -p "$BACKUP_ROOT/work"
capture_log
with_lock

HC_URL=""
[ "$TAG" = scheduled ] && HC_URL=$HC_BACKUP_URL
STAGING="$BACKUP_ROOT/staging"
STARTED=$(date +%s)

finish() {
  local rc=$?
  rm -rf "$STAGING"
  if [ "$rc" -eq 0 ]; then
    hc_ping "$HC_URL" success "$(tail -n 20 "$RUN_LOG")"
  else
    log "FAILED (exit $rc)"
    hc_ping "$HC_URL" fail "$(tail -n 50 "$RUN_LOG")"
  fi
  rm -f "$RUN_LOG"
}
trap finish EXIT
hc_ping "$HC_URL" start

rm -rf "$STAGING"
mkdir -p "$STAGING/db"

# --- 1. Consistent dump -------------------------------------------------------------------
# A REPEATABLE READ transaction exports its snapshot; pg_dump reuses it (--snapshot) and the
# row counts run inside it, so the counts describe exactly the rows of the dump.
log "dumping $POSTGRES_DB ($TAG)"
# shellcheck disable=SC2016 # expanded inside the container
coproc PSQL { pg_exec sh -c 'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -AtqX -v ON_ERROR_STOP=1'; }
printf 'BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY;\nSELECT pg_export_snapshot();\n' >&"${PSQL[1]}"
read -r -t 60 snapshot <&"${PSQL[0]}" || die "could not export a snapshot"
printf '%s\nSELECT %s;\n' "$ROWCOUNT_SQL" "'__END__'" >&"${PSQL[1]}"
while read -r -t 300 line <&"${PSQL[0]}"; do
  [ "$line" = __END__ ] && break
  printf '%s\n' "$line"
done >"$STAGING/db/rowcounts.tsv"
[ "$line" = __END__ ] || die "row count query did not complete"

# shellcheck disable=SC2016 # expanded inside the container
pg_exec sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --compress=0 --snapshot="$1"' \
  sh "$snapshot" >"$STAGING/db/keimelion.dump"

printf 'COMMIT;\n' >&"${PSQL[1]}"
psql_in=${PSQL[1]}
exec {psql_in}>&-
wait "$PSQL_PID" || die "snapshot transaction failed"

# shellcheck disable=SC2016
pg_exec sh -c 'exec pg_dumpall -U "$POSTGRES_USER" --globals-only --no-role-passwords' >"$STAGING/db/globals.sql"

# The archive must at least be readable by pg_restore (full restore: backup-verify.sh).
pg_exec pg_restore --list <"$STAGING/db/keimelion.dump" >/dev/null || die "pg_restore cannot read the dump"

uploads_files=0
[ -d "$UPLOADS_DIR" ] && uploads_files=$(find "$UPLOADS_DIR" -type f | wc -l)
{
  echo "created_at=$(date -Is)"
  echo "created_epoch=$(date +%s)"
  echo "tag=$TAG"
  echo "database=$POSTGRES_DB"
  echo "postgres_version=$(pg_exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -AtqX -c 'SHOW server_version')"
  echo "postgres_image=$(docker inspect --format '{{.Config.Image}}@{{.Image}}' "$(compose ps -q postgres)")"
  echo "infra_commit=$(git -C "$INFRA_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "api_commit=$(git -C "$INFRA_DIR/../Keimelion-API" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "dump_bytes=$(stat -c %s "$STAGING/db/keimelion.dump")"
  echo "dump_sha256=$(sha256sum "$STAGING/db/keimelion.dump" | cut -d' ' -f1)"
  echo "tables=$(wc -l <"$STAGING/db/rowcounts.tsv")"
  echo "uploads_files=$uploads_files"
} >"$STAGING/manifest.env"
log "dump OK: $(grep -E '^(dump_bytes|tables|uploads_files)=' "$STAGING/manifest.env" | tr '\n' ' ')"

# --- 2. Local snapshot + retention --------------------------------------------------------
paths=("$STAGING" "$ENV_FILE")
[ -d "$UPLOADS_DIR" ] && paths+=("$UPLOADS_DIR")
tags=(--tag "$TAG")
[ -n "$LABEL" ] && tags+=(--tag "$LABEL")
snapshot_id=$(restic_local backup --json --quiet --host keimelion "${tags[@]}" "${paths[@]}" |
  sed -n 's/.*"message_type":"summary".*"snapshot_id":"\([0-9a-f]*\)".*/\1/p')
[ -n "$snapshot_id" ] || die "restic backup did not report a snapshot ID"
log "snapshot ${snapshot_id:0:8}"
if [ -n "$LABEL" ]; then
  echo "$snapshot_id $(date +%s)" >"$BACKUP_ROOT/last-pre-deploy-$LABEL"
fi

read -ra retention <<<"$(env_get BACKUP_RETENTION '--keep-last 4 --keep-daily 14 --keep-weekly 8 --keep-monthly 12')"
restic_local forget --quiet --host keimelion --group-by host,tags "${retention[@]}" --prune

# --- 3. Off-site copy ---------------------------------------------------------------------
offsite() {
  restic_offsite copy --quiet --from-repo "$RESTIC_LOCAL_REPOSITORY" --from-password-file "$RESTIC_PASSWORD_FILE" &&
    restic_offsite forget --quiet --host keimelion --group-by host,tags "${retention[@]}" --prune
}
if [ -z "$RESTIC_OFFSITE_REPOSITORY" ]; then
  log "WARN: RESTIC_OFFSITE_REPOSITORY not set, no off-site copy"
elif offsite; then
  log "off-site copy OK"
elif [ "$TAG" = scheduled ]; then
  die "off-site copy to $RESTIC_OFFSITE_REPOSITORY failed"
else
  log "WARN: off-site copy failed, the next scheduled run will retry it"
fi

log "backup OK in $(($(date +%s) - STARTED))s"
