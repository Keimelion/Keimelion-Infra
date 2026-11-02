#!/usr/bin/env bash
# Creates or updates (matched by name) the branch rulesets of github/rulesets/*.json
# on the Keimelion app repos. Needs a gh token with admin rights on the repos.
#
#   scripts/apply-rulesets.sh                      # the three app repos
#   scripts/apply-rulesets.sh Keimelion-API        # one repo
set -euo pipefail

cd "$(dirname "$0")/.."

OWNER=Keimelion
REPOS=("$@")
if [ ${#REPOS[@]} -eq 0 ]; then
  REPOS=(Keimelion-API Keimelion-Backoffice Keimelion-Landing)
fi

for repo in "${REPOS[@]}"; do
  for file in github/rulesets/*.json; do
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
