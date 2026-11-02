# CI, release & deploy

One process, identical for the three app repos (API, Back-office, Landing).
The logic lives in the **reusable workflows** of this repo; each app repo holds the
same thin callers, **byte-for-byte identical** (no inputs):

| In each app repo | Calls (here) | Role |
|---|---|---|
| `ci.yml` (PR → dev/main, push dev) | `node-ci.yml`, `pr-title.yml`, `dependabot-automerge.yml` | `npm ci` + `lint typecheck test build` (missing scripts skipped), `.env.example` as build env; PR title = Conventional Commit; Dependabot patch/minor PRs squash-merged once green (majors left for review) |
| `release.yml` (push main) | `node-ci.yml` → `release.yml` → `deploy.yml` | semantic-release, fast-forward `dev` onto `main`, deploy if a tag was created |
| `deploy.yml` (manual) | `deploy.yml` | redeploy `main` |
| `codeql.yml` | `codeql.yml` | CodeQL `security-and-quality` |

Also identical in each app repo: `.releaserc.json`, `.commitlintrc.json`,
`.husky/commit-msg`, `.github/dependabot.yml`, `.nvmrc` (`24`).

Repo-specific values (compose service, health URL) are resolved in `deploy.yml` from
the repo name — they sit here next to `docker-compose.yml`. Callers reference `@main`:
merging here changes the pipeline of every repo at once (`lint.yml` runs actionlint on
every PR here).

## Flow

```
 feat/KEI-xx ──PR (squash)──▶ dev                     ci.yml: node-ci + pr-title
                               │
                Release PR dev → main  (MERGE COMMIT — never squash)
                               │
                               ▼
 main ─ push ─▶ release.yml:  ci ──▶ release ──▶ deploy (only if a tag was created)
                                       │  semantic-release: vX.Y.Z tag, GitHub Release,
                                       │  CHANGELOG.md + package.json, "chore(release) [skip ci]"
                                       └─ fast-forward dev ← main (sync PR if dev moved meanwhile)
```

### Why a merge commit for the release PR

semantic-release reads the commits between the last tag and `main`. A merge commit
keeps every squashed feature commit of `dev`, so the bump and the CHANGELOG reflect
each PR. A squashed release PR would collapse them into one commit, and would make
`dev` and `main` diverge forever. Feature PRs into `dev` stay squashed (one PR = one
Conventional Commit, validated by `pr-title.yml` and, locally, by commitlint).

## Commit convention → version

The bump is **computed**, never chosen by hand: semantic-release
(`conventionalcommits` preset) takes the highest bump among the commits since the
last tag. With squash merges, "commit" = **PR title** (+ PR description for footers).

| PR title | Bump | Example |
|---|---|---|
| `fix: …` | patch `1.2.3 → 1.2.4` | `fix: lists/:id 404 on archived list (KEI-150)` |
| `perf: …`, `revert: …` | patch | `perf: index list_items.list_id (KEI-151)` |
| `feat: …` | minor `1.2.3 → 1.3.0` | `feat: users/me/export CSV (KEI-37)` |
| `<type>!: …` or `BREAKING CHANGE:` footer | major `1.2.3 → 2.0.0` | `feat!: drop /v0 routes (KEI-160)` |
| `chore`, `ci`, `docs`, `refactor`, `test`, `style`, `build` | none — no tag, no deploy | `chore: bump deps` |

- The release PR title doesn't matter (merge commits are ignored): use `chore: release`.
- The release commit is written by semantic-release: `chore(release): X.Y.Z [skip ci]`.
- To ship a dependency bump or refactor anyway, title it `fix:` (or merge it with a
  `fix`/`feat` in the same release).

## Releasing

1. Open a PR `dev → main` titled `chore: release`, wait for CI.
2. **Merge with "Create a merge commit"**.
3. Watch the `Release` run: tag + GitHub Release, `dev` fast-forwarded, then deploy.

Manual redeploy of `main` (e.g. after a server rebuild): `Deploy` workflow → *Run workflow*.

## One-time GitHub setup

- **Self-hosted runner on public repos**: org *Settings → Actions → General* →
  *Require approval for all external contributors* for fork PR workflows. A fork PR
  could otherwise add a job `runs-on: [self-hosted, keimelion]` and run code on
  milky-way. If the plan allows runner groups, restrict the `keimelion` runner to
  the `Keimelion-Infra/.github/workflows/deploy.yml` workflow.
- **Branches & merge methods** (all three app repos): default branch `dev`; allow
  *squash* (feature PRs) **and** *merge commits* (release PRs).
- **Release GitHub App** (needed as soon as `main`/`dev` are protected): create an
  org App with *Contents: read & write*, *Issues* and *Pull requests: read & write*,
  install it on the three repos, store `RELEASE_APP_ID` and
  `RELEASE_APP_PRIVATE_KEY` as **org secrets**, and add the App as bypass actor of
  the rulesets. Without these secrets the release falls back to `GITHUB_TOKEN`.
- **Rulesets** on `main` and `dev`: require a PR, require the `CI` status checks
  (`ci / …`, `pr-title / …`), block force-push and deletion.
