# shellcheck shell=bash disable=SC2034 # variables are used by the sourcing scripts
# Shared helpers for scripts/backup/*.sh — sourced, never executed.
# Configuration comes from Keimelion-Infra/.env (BACKUP_*, RESTIC_*, HC_*): see .env.example
# and docs/backup.md.

set -euo pipefail
umask 077

INFRA_DIR=${KEIMELION_INFRA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
ENV_FILE="$INFRA_DIR/.env"

log() { printf '%s [%s] %s\n' "$(date -Is)" "${SCRIPT_NAME:-backup}" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Reads KEY from .env without sourcing it (values may contain spaces, <, >, ...).
# The process environment wins, so any setting can be overridden for a one-off run.
env_get() {
  local key=$1 default=${2-} value
  if [ -n "${!key+x}" ]; then printf '%s' "${!key}"; return; fi
  value=$(sed -n "s/^${key}=//p" "$ENV_FILE" 2>/dev/null | tail -n 1)
  value=${value%\"}; value=${value#\"}
  printf '%s' "${value:-$default}"
}

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found"

BACKUP_ROOT=$(env_get BACKUP_ROOT /var/backups/keimelion)
RESTIC_LOCAL_REPOSITORY=$(env_get RESTIC_LOCAL_REPOSITORY "$BACKUP_ROOT/restic")
RESTIC_OFFSITE_REPOSITORY=$(env_get RESTIC_OFFSITE_REPOSITORY)
RESTIC_PASSWORD_FILE=$(env_get RESTIC_PASSWORD_FILE "$INFRA_DIR/secrets/restic-password")
HC_BACKUP_URL=$(env_get HC_BACKUP_URL)
HC_VERIFY_URL=$(env_get HC_VERIFY_URL)
POSTGRES_USER=$(env_get POSTGRES_USER)
POSTGRES_DB=$(env_get POSTGRES_DB)
API_PORT=$(env_get API_PORT 3000)
UPLOADS_DIR="$INFRA_DIR/data/uploads"
export RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR=${RESTIC_CACHE_DIR:-$BACKUP_ROOT/cache}

[ -d "$BACKUP_ROOT" ] || die "$BACKUP_ROOT does not exist (run scripts/backup/install.sh)"
[ "${SCRIPT_NAME-}" = init-repos ] || [ -r "$RESTIC_PASSWORD_FILE" ] || die "restic password file $RESTIC_PASSWORD_FILE unreadable (run scripts/backup/init-repos.sh)"
command -v restic >/dev/null || die "restic is not installed (run scripts/backup/install.sh)"

compose() { docker compose --project-directory "$INFRA_DIR" "$@"; }

# Runs a command inside the postgres service, with the container's own POSTGRES_* env.
pg_exec() { compose exec -T postgres "$@"; }

restic_local() { restic --repo "$RESTIC_LOCAL_REPOSITORY" "$@"; }
restic_offsite() { restic --repo "$RESTIC_OFFSITE_REPOSITORY" "$@"; }

# Selects the repository to read from: "local" or "offsite".
restic_from() {
  local which=$1; shift
  case "$which" in
    local) restic_local "$@" ;;
    offsite)
      [ -n "$RESTIC_OFFSITE_REPOSITORY" ] || die "RESTIC_OFFSITE_REPOSITORY is not set"
      restic_offsite "$@" ;;
    *) die "unknown repository '$which' (local|offsite)" ;;
  esac
}

# Serialises backup / verify / restore: they must never prune or restore concurrently.
with_lock() {
  exec 9>"$BACKUP_ROOT/.lock"
  flock -w 900 9 || die "another backup job holds $BACKUP_ROOT/.lock"
}

# One row per user table, "schema.table<TAB>exact row count", sorted. Run in the same
# transaction as pg_dump (backup) and against the restored copy (verify/restore): both
# sides must match exactly.
ROWCOUNT_SQL="SELECT format('%I.%I', schemaname, tablename) || E'\t' ||
  (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', schemaname, tablename), false, true, '')))[1]::text
FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1;"

# Monitoring pings (no-op when the URL is empty). $2: start | success | fail.
# Healthchecks.io: POST <url>[/start|/fail] with the log tail as body.
# Uptime Kuma push monitor (<kuma>/api/push/<token>, query string ignored): no start event,
# GET ?status=up|down with a one-line message (the last ERROR line on failure).
hc_ping() {
  local url=$1 event=$2 body=${3-} msg
  [ -n "$url" ] || return 0
  if [[ "$url" == */api/push/* ]]; then
    [ "$event" = start ] && return 0
    msg=$(printf '%s\n' "$body" | grep 'ERROR' | tail -n 1 || true)
    [ -n "$msg" ] || msg=$(printf '%s\n' "$body" | tail -n 1)
    msg=${msg#*] }
    curl -fsS -m 10 --retry 3 -o /dev/null -G --data-urlencode "status=$([ "$event" = fail ] && echo down || echo up)" \
      --data-urlencode "msg=${msg:0:200}" "${url%%\?*}" || log "WARN: Uptime Kuma ping failed ($event)"
    return 0
  fi
  case "$event" in
    start) url="$url/start" ;;
    fail) url="$url/fail" ;;
  esac
  curl -fsS -m 10 --retry 3 -o /dev/null --data-binary "$body" "$url" || log "WARN: Healthchecks ping failed ($event)"
}

# Captures this script's stderr in a log file so the failure ping can carry its tail.
capture_log() {
  RUN_LOG=$(mktemp "$BACKUP_ROOT/work/run.XXXXXX.log")
  exec 2> >(tee -a "$RUN_LOG" >&2)
}
