#!/usr/bin/env bash
# Steps of the app deploy (.github/workflows/deploy.yml), kept here so they can be rehearsed
# on a throwaway compose project (KEIMELION_INFRA_DIR=<dir>). Policy: docs/runbook.md
# "Deploy, migrations & rollback".
#
#   app-deploy.sh save-image <service>          tag the running image <image>:previous
#   app-deploy.sh migrate                       apply the new API image's migrations while
#                                               the current API keeps serving
#   app-deploy.sh check <url> [<url>...]        first URL: wait for it (~90 s); the others
#                                               (smoke tests) must answer 2xx right after
#   app-deploy.sh rollback <service> <url>...   previous image back (instant), checked; for
#                                               the API, if this deploy migrated the schema
#                                               (SCHEMA_CHANGED=true) and the previous release
#                                               is unhealthy on it: restore the pre-deploy
#                                               snapshot, checked again
#
# RESTORE_CMD overrides the restore (default: the <BACKUP_UNIT_PREFIX>-db-restore@pre-deploy-api unit,
# prefix keimelion unless set).
set -euo pipefail

INFRA_DIR=${KEIMELION_INFRA_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}
compose() { docker compose --project-directory "$INFRA_DIR" "$@"; }
notice() { echo "::notice::$*"; }
warning() { echo "::warning::$*"; }
error() { echo "::error::$*"; }

# Image built for a service without `image:` in the compose file: <project>-<service>.
image_of() { echo "$(compose config | sed -n 's/^name: //p')-$1"; }

output() {
  echo "$1"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >>"$GITHUB_OUTPUT"; fi
}

save_image() {
  local service=$1 image cid
  image=$(image_of "$service")
  cid=$(compose ps -q "$service")
  if [ -z "$cid" ]; then
    warning "no running $service container: a rollback would rebuild the previous commit"
    return 0
  fi
  docker tag "$(docker inspect --format '{{.Image}}' "$cid")" "$image:previous"
  notice "running $service image saved as $image:previous"
}

# Applied migrations; 0 before the very first one.
# shellcheck disable=SC2016 # expanded inside the container
migration_count() {
  compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -AtqX -c "SELECT count(*) FROM drizzle.__drizzle_migrations"' 2>/dev/null || echo 0
}

# Drizzle applies all pending migrations in ONE transaction: a failure leaves the schema
# untouched, and the current container was never stopped.
migrate() {
  local before after rc=0
  before=$(migration_count)
  compose run --rm --no-deps -T api npm run --silent db:migrate || rc=$?
  after=$(migration_count)
  output "schema_changed=$([ "$before" != "$after" ] && echo true || echo false)"
  if [ "$rc" -ne 0 ]; then
    error "migration failed (exit $rc): schema unchanged ($after applied), the running API was not touched"
    return "$rc"
  fi
  notice "migrations: $before -> $after applied"
}

check() {
  local first=$1 i
  shift
  for i in $(seq 1 "${HEALTH_ATTEMPTS:-30}"); do
    if curl -fs -o /dev/null --max-time 5 "$first"; then break; fi
    if [ "$i" -eq "${HEALTH_ATTEMPTS:-30}" ]; then
      error "health check failed after $i attempts on $first"
      return 1
    fi
    sleep 3
  done
  for url in "$@"; do
    if ! curl -fsS -o /dev/null --max-time 5 --retry 2 --retry-delay 2 --retry-all-errors "$url"; then
      error "smoke test failed on $url"
      return 1
    fi
  done
  notice "healthy: $first $*"
}

rollback() {
  local service=$1 image
  shift
  image=$(image_of "$service")
  if docker image inspect "$image:previous" >/dev/null 2>&1; then
    docker tag "$image:previous" "$image:latest"
    compose up -d --no-build "$service"
  else
    warning "no $image:previous, rebuilding the previous commit"
    compose up -d --build "$service"
  fi
  if check "$@"; then
    warning "$service rolled back to the previous release"
    return 0
  fi

  if [ "$service" != api ] || [ "${SCHEMA_CHANGED:-false}" != true ]; then
    error "$service still unhealthy after the rollback: manual intervention needed"
    return 1
  fi
  warning "previous release unhealthy on the migrated schema: restoring the pre-deploy snapshot"
  if [ -n "${RESTORE_CMD:-}" ]; then
    bash -c "$RESTORE_CMD" || { error "restore failed"; return 1; }
  else
    sudo -n systemctl start --wait "${BACKUP_UNIT_PREFIX:-keimelion}-db-restore@pre-deploy-api.service" || {
      error "restore failed (journalctl -u ${BACKUP_UNIT_PREFIX:-keimelion}-db-restore@pre-deploy-api)"
      return 1
    }
  fi
  if check "$@"; then
    warning "database restored to the pre-deploy snapshot, previous release healthy (writes since the snapshot are lost; the broken state is in the pre-restore snapshot)"
    return 0
  fi
  error "API unhealthy even after the restore: manual intervention needed (docs/backup.md)"
  return 1
}

cmd=${1:?usage: $0 save-image|migrate|check|rollback ...}
shift
case "$cmd" in
  save-image) save_image "$@" ;;
  migrate) migrate ;;
  check) check "$@" ;;
  rollback) rollback "$@" ;;
  *) echo "unknown command $cmd" >&2; exit 2 ;;
esac
