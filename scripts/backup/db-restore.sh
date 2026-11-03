#!/usr/bin/env bash
# Restores a restic snapshot into PRODUCTION. Procedure and rollback: docs/backup.md.
#
#   scripts/backup/db-restore.sh [--from local|offsite] [--snapshot ID | --last pre-deploy-<name>]
#                                [--with-uploads] [--skip-safety-backup] [--yes]
#
#   1. restores the snapshot (default: latest) to a work dir and checks the dump checksum
#   2. takes a "pre-restore" backup of the current state (unless --skip-safety-backup)
#   3. pg_restore into <db>_restore, next to the live database, and checks its row counts
#   4. stops the API, swaps the databases by renaming (<db> -> <db>_pre_restore_<ts>,
#      <db>_restore -> <db>), restarts the API (which applies newer migrations) and waits
#      for /health. The previous database is kept until dropped by hand.
#   --last pre-deploy-<name>  the snapshot recorded by `db-backup.sh pre-deploy-<name>`
#                   (deploy rollback, run by keimelion-db-restore@.service); refused when
#                   older than BACKUP_LAST_MAX_AGE_MINUTES (60): it must be this deploy's
#   --with-uploads  also copies the snapshot's uploads missing from data/uploads (never
#                   overwrites nor deletes a file)
SCRIPT_NAME=db-restore
FROM=local
SNAPSHOT=latest
LAST=""
WITH_UPLOADS=false
SAFETY_BACKUP=true
ASSUME_YES=false
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM=$2; shift 2 ;;
    --snapshot) SNAPSHOT=$2; shift 2 ;;
    --last) LAST=$2; shift 2 ;;
    --with-uploads) WITH_UPLOADS=true; shift ;;
    --skip-safety-backup) SAFETY_BACKUP=false; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h | --help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done

# shellcheck source=scripts/backup/lib.sh
. "$(dirname "$0")/lib.sh"

if [ -n "$LAST" ]; then
  [[ "$LAST" =~ ^pre-deploy-[a-z0-9]+$ ]] || die "invalid --last '$LAST'"
  read -r SNAPSHOT recorded_at <"$BACKUP_ROOT/last-$LAST" || die "no snapshot recorded for $LAST"
  [[ "$SNAPSHOT" =~ ^[0-9a-f]{64}$ ]] || die "invalid snapshot ID in $BACKUP_ROOT/last-$LAST"
  age_minutes=$((($(date +%s) - recorded_at) / 60))
  [ "$age_minutes" -le "$(env_get BACKUP_LAST_MAX_AGE_MINUTES 60)" ] ||
    die "$LAST snapshot is ${age_minutes} min old: not this deploy's, refusing (use --snapshot)"
  FROM=local
  log "$LAST snapshot ${SNAPSHOT:0:8}, taken ${age_minutes} min ago"
fi

DB=$POSTGRES_DB
RESTORE_DB="${DB}_restore"
OLD_DB="${DB}_pre_restore_$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_ROOT/work"
WORK=$(mktemp -d "$BACKUP_ROOT/work/restore.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --host only filters "latest": restic ignores (and warns about) filters next to an explicit ID.
filters=()
[ "$SNAPSHOT" = latest ] && filters=(--host keimelion)

psql_admin() { pg_exec psql -U "$POSTGRES_USER" -d postgres -AtqX -v ON_ERROR_STOP=1 "$@"; }

# --- 1. Fetch the snapshot ----------------------------------------------------------------
restic_from "$FROM" snapshots "${filters[@]}" --compact "$SNAPSHOT" >&2
log "restoring snapshot $SNAPSHOT from $FROM to a work dir"
restic_from "$FROM" restore "$SNAPSHOT" "${filters[@]}" --target "$WORK" --verify --quiet
dump=$(find "$WORK" -path '*/staging/db/keimelion.dump' -print -quit)
[ -n "$dump" ] || die "no staging/db/keimelion.dump in snapshot $SNAPSHOT"
staging=$(dirname "$(dirname "$dump")")
manifest() { sed -n "s/^$1=//p" "$staging/manifest.env"; }
[ "$(sha256sum "$dump" | cut -d' ' -f1)" = "$(manifest dump_sha256)" ] || die "dump checksum mismatch"

cat >&2 <<EOF

  Snapshot   : $(manifest created_at)  (tag $(manifest tag))
  Content    : $(manifest tables) tables, $(manifest uploads_files) uploads, Postgres $(manifest postgres_version)
  API commit : $(manifest api_commit)
  Target     : database "$DB" on $(hostname) — the API will be stopped during the swap
  Uploads    : $([ "$WITH_UPLOADS" = true ] && echo "missing files copied into data/uploads" || echo "untouched")

EOF
if [ "$ASSUME_YES" != true ]; then
  read -r -p "Type the database name ($DB) to restore it: " answer
  [ "$answer" = "$DB" ] || die "aborted"
fi

# --- 2. Safety backup of the current state ------------------------------------------------
if [ "$SAFETY_BACKUP" = true ]; then
  "$(dirname "$0")/db-backup.sh" pre-restore || die "safety backup failed (--skip-safety-backup if the database is unusable)"
fi
with_lock

# --- 3. Restore next to the live database -------------------------------------------------
log "pg_restore into $RESTORE_DB"
psql_admin -c "DROP DATABASE IF EXISTS \"$RESTORE_DB\" WITH (FORCE)"
psql_admin -c "CREATE DATABASE \"$RESTORE_DB\" OWNER \"$POSTGRES_USER\""
pg_exec pg_restore -U "$POSTGRES_USER" -d "$RESTORE_DB" --exit-on-error --single-transaction <"$dump"
pg_exec psql -U "$POSTGRES_USER" -d "$RESTORE_DB" -AtqX -v ON_ERROR_STOP=1 -c "$ROWCOUNT_SQL" >"$WORK/rowcounts.restored.tsv"
diff -u "$staging/db/rowcounts.tsv" "$WORK/rowcounts.restored.tsv" >&2 || die "row counts of $RESTORE_DB differ from the backup, live database untouched"
log "$RESTORE_DB matches the backup"

# --- 4. Swap ------------------------------------------------------------------------------
log "stopping the API and swapping $DB -> $OLD_DB, $RESTORE_DB -> $DB"
compose stop api
psql_admin -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('$DB', '$RESTORE_DB') AND pid <> pg_backend_pid()" >/dev/null
psql_admin -c "ALTER DATABASE \"$DB\" RENAME TO \"$OLD_DB\""
psql_admin -c "ALTER DATABASE \"$RESTORE_DB\" RENAME TO \"$DB\""

if [ "$WITH_UPLOADS" = true ]; then
  uploads=$(find "$WORK" -type d -path '*/data/uploads' -print -quit)
  if [ -n "$uploads" ]; then
    cp -a --update=none "$uploads/." "$UPLOADS_DIR/"
    log "uploads merged into $UPLOADS_DIR"
  fi
fi

compose start api
log "waiting for http://127.0.0.1:$API_PORT/health"
for _ in $(seq 1 45); do
  if curl -fs -o /dev/null --max-time 3 "http://127.0.0.1:$API_PORT/health"; then
    log "RESTORE OK. Previous database kept as $OLD_DB; once satisfied:"
    log "  docker compose exec postgres dropdb -U $POSTGRES_USER '$OLD_DB'"
    exit 0
  fi
  sleep 2
done

cat >&2 <<EOF
$(date -Is) [$SCRIPT_NAME] ERROR: the API is not healthy after the restore (docker compose logs api).
To roll back to the database as it was before the restore:
  docker compose stop api
  docker compose exec postgres psql -U $POSTGRES_USER -d postgres -c 'ALTER DATABASE "$DB" RENAME TO "${DB}_failed_restore"'
  docker compose exec postgres psql -U $POSTGRES_USER -d postgres -c 'ALTER DATABASE "$OLD_DB" RENAME TO "$DB"'
  docker compose start api
EOF
exit 1
