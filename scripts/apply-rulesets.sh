#!/usr/bin/env bash
# Creates or updates (matched by name) the branch rulesets of github/rulesets/<kind>/*.json
# on the Keimelion repos. Needs a gh token with admin rights on the repos.
#
#   apps/         Keimelion-API, Keimelion-Backoffice, Keimelion-Landing, Keimelion-SDK
#   infra/        Keimelion-Infra
#   collections/  Keimelion-API-collections
#
#   scripts/apply-rulesets.sh                      # every repo
#   scripts/apply-rulesets.sh Keimelion-API        # one repo
set -euo pipefail

cd "$(dirname "$0")/.."

OWNER=Keimelion
REPOS=("$@")
if [ ${#REPOS[@]} -eq 0 ]; then
  REPOS=(Keimelion-API Keimelion-Backoffice Keimelion-Landing Keimelion-SDK Keimelion-Infra Keimelion-API-collections)
fi

for repo in "${REPOS[@]}"; do
  case "$repo" in
    Keimelion-Infra) kind=infra ;;
    Keimelion-API-collections) kind=collections ;;
    *) kind=apps ;;
  esac
  for file in github/rulesets/"$kind"/*.json; do
    name=$(sed -n 's/^  "name": "\(.*\)",$/\1/p' "$file")
    id=$(gh api "repos/$OWNER/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id")
    if [ -n "$id" ]; then
      gh api --method PUT "repos/$OWNER/$repo/rulesets/$id" --input "$file" --silent
      echo "$repo: updated ruleset '$name' ($id)"
    else
      gh api --method POST "repos/$OWNER/$repo/rulesets" --input "$file" --silent
      echo "$repo: created ruleset '$name'"
    fi
  done
done
