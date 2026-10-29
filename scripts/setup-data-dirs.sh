#!/usr/bin/env bash
set -euo pipefail
# Create bind-mount data directories with the right ownership so Docker
# doesn't create them as root at first `up`. The API runs as uid 1000 (node)
# and needs write access to uploads/. Postgres manages its own permissions
# inside its volume so we only touch host-visible ones here.
cd "$(dirname "$0")/.."
mkdir -p data/uploads data/postgres
chown -R 1000:1000 data/uploads
chmod 0755 data data/uploads
