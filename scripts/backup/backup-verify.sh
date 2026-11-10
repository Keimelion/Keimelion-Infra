#!/usr/bin/env bash
# Proves the backups can be restored. Run weekly by keimelion-backup-verify.timer.
#
#   scripts/backup/backup-verify.sh [auto|local|offsite]   (default: auto = offsite if configured)
#
#   1. restic check of both repositories, reading a random subset of the pack files
#   2. restore of the latest snapshot (with restic --verify) from the chosen repository
#   3. freshness and checksum of the dump against its manifest
#   4. pg_restore into a throwaway Postgres container (same image as production, no network)
#   5. exact comparison of every table's row count with the counts taken at backup time
# Pings HC_VERIFY_URL (Uptime Kuma or Healthchecks.io); production is never touched.
SCRIPT_NAME=backup-verify
FROM=${1:-auto}

# shellcheck source=scripts/backup/lib.sh
. "$(dirname "$0")/lib.sh"

if [ "$FROM" = auto ]; then
  FROM=local
  [ -n "$RESTIC_OFFSITE_REPOSITORY" ] && FROM=offsite
fi
MAX_AGE_HOURS=$(env_get BACKUP_MAX_AGE_HOURS 12)
READ_SUBSET=$(env_get BACKUP_VERIFY_READ_SUBSET 10%)

mkdir -p "$BACKUP_ROOT/work"
capture_log
with_lock

WORK=$(mktemp -d "$BACKUP_ROOT/work/verify.XXXXXX")
CONTAINER="$(env_get COMPOSE_PROJECT_NAME keimelion)-restore-test-$$"
STARTED=$(date +%s)

finish() {
  local rc=$?
  docker rm -f -v "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  if [ "$rc" -eq 0 ]; then
    hc_ping "$HC_VERIFY_URL" success "$(tail -n 20 "$RUN_LOG")"
  else
    log "FAILED (exit $rc)"
    hc_ping "$HC_VERIFY_URL" fail "$(tail -n 50 "$RUN_LOG")"
  fi
  rm -f "$RUN_LOG"
}
trap finish EXIT
hc_ping "$HC_VERIFY_URL" start

# --- 1. Repository integrity --------------------------------------------------------------
log "restic check local (read $READ_SUBSET)"
restic_local check --quiet --read-data-subset="$READ_SUBSET"
if [ -n "$RESTIC_OFFSITE_REPOSITORY" ]; then
  log "restic check offsite (read $READ_SUBSET)"
  restic_offsite check --quiet --read-data-subset="$READ_SUBSET"
fi

# --- 2. Restore ---------------------------------------------------------------------------
log "restoring the latest snapshot from $FROM"
restic_from "$FROM" snapshots --host keimelion --compact latest >&2
restore_started=$(date +%s)
restic_from "$FROM" restore latest --host keimelion --target "$WORK" --verify --quiet

dump=$(find "$WORK" -path '*/staging/db/keimelion.dump' -print -quit)
[ -n "$dump" ] || die "no staging/db/keimelion.dump in the snapshot"
staging=$(dirname "$(dirname "$dump")")
manifest() { sed -n "s/^$1=//p" "$staging/manifest.env"; }

# --- 3. Freshness + checksum --------------------------------------------------------------
age_hours=$((($(date +%s) - $(manifest created_epoch)) / 3600))
log "snapshot: $(manifest created_at) (tag $(manifest tag), ${age_hours}h old), api $(manifest api_commit | cut -c1-7)"
[ "$age_hours" -le "$MAX_AGE_HOURS" ] || die "latest $FROM snapshot is ${age_hours}h old (max ${MAX_AGE_HOURS}h)"
[ "$(sha256sum "$dump" | cut -d' ' -f1)" = "$(manifest dump_sha256)" ] || die "dump checksum mismatch"

# --- 4. Restore into a throwaway Postgres -------------------------------------------------
image=$(docker inspect --format '{{.Image}}' "$(compose ps -q postgres)")
docker run -d --name "$CONTAINER" --network none \
  -e POSTGRES_USER="$POSTGRES_USER" -e POSTGRES_DB="$POSTGRES_DB" \
  -e POSTGRES_PASSWORD="$(head -c 24 /dev/urandom | base64)" \
  "$image" >/dev/null
# During init the entrypoint runs a temporary server on the Unix socket only: TCP answers
# once the real server is up.
for _ in $(seq 1 60); do
  docker exec "$CONTAINER" pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER" && break
  sleep 1
done
docker exec "$CONTAINER" pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER" || die "throwaway Postgres did not start"

log "pg_restore into $CONTAINER"
docker exec -i "$CONTAINER" psql -U "$POSTGRES_USER" -d postgres -qX >/dev/null 2>&1 <"$staging/db/globals.sql" || true
docker exec -i "$CONTAINER" pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --exit-on-error --single-transaction <"$dump"
restore_seconds=$(($(date +%s) - restore_started))

# --- 5. Row counts ------------------------------------------------------------------------
docker exec "$CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -AtqX -v ON_ERROR_STOP=1 -c "$ROWCOUNT_SQL" >"$WORK/rowcounts.restored.tsv"
if ! diff -u "$staging/db/rowcounts.tsv" "$WORK/rowcounts.restored.tsv" >&2; then
  die "row counts of the restored database differ from the backup"
fi
rows=$(awk -F'\t' '{ s += $2 } END { print s + 0 }' "$WORK/rowcounts.restored.tsv")
migrations=$(awk -F'\t' '$1 == "drizzle.__drizzle_migrations" { print $2 }' "$WORK/rowcounts.restored.tsv")

uploads=$(find "$WORK" -path '*/data/uploads/*' -type f | wc -l)
[ "$uploads" -eq "$(manifest uploads_files)" ] || log "WARN: $uploads uploads restored, manifest says $(manifest uploads_files) (upload or deletion during the backup)"

log "verify OK in $(($(date +%s) - STARTED))s: $(wc -l <"$WORK/rowcounts.restored.tsv") tables, $rows rows, ${migrations:-0} migrations, $uploads uploads; restore time ${restore_seconds}s (from $FROM)"
