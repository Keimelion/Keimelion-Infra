# CI, release & deploy

One process, identical for the three app repos (API, Back-office, Landing) and the
npm package repo (Keimelion-SDK, `@keimelion/sdk`).
The logic lives in the **reusable workflows** of this repo; each app repo holds the
same thin callers, **byte-for-byte identical** (no inputs). The SDK has no `deploy.yml`
caller: its `release.yml` publishes to npmjs instead
(see [npm package](#npm-package-keimelion-sdk)).

| In each app repo | Calls (here) | Role |
|---|---|---|
| `ci.yml` (PR → dev/main, push dev) | `node-ci.yml`, `pr-title.yml`, `dependabot-automerge.yml` | `npm ci` + `lint typecheck test build` (missing scripts skipped), `.env.example` as build env; PR title = Conventional Commit; Dependabot patch/minor PRs squash-merged once green (majors and Keimelion-Infra updates left for review) |
| `release.yml` (push main) | `node-ci.yml` → `release.yml` (SDK: + `npm-publish.yml`) | semantic-release, fast-forward `dev` onto `main` (SDK: publish to npmjs if a tag was created) |
| `deploy.yml` (`CI` green on a push to dev, `Release` green on main, or manual) | `deploy.yml` | deploy `dev` to the pre-prod, `main` to the production |
| `codeql.yml` | `codeql.yml` | CodeQL `security-and-quality` |

Also identical in each app repo: `.releaserc.json`, `.commitlintrc.json`,
`.husky/commit-msg`, `.github/dependabot.yml`, `.nvmrc` (`24`).

Repo-specific values (compose service, health URL) are resolved in `deploy.yml` from
the repo name — they sit here next to `docker-compose.yml`. Callers pin an exact tag of
this repo (`@vX.Y.Z`): a change merged here reaches an app repo only when that repo merges
its own update PR, see [Versioning of the reusable workflows](#versioning-of-the-reusable-workflows)
(`lint.yml` runs actionlint on every PR here).

## Flow

```
 feat/KEI-xx ──PR (squash)──▶ dev                     ci.yml: node-ci + pr-title
                               │  CI green on the push ──▶ deploy.yml: pre-prod runs dev
                               │
                Release PR dev → main  (MERGE COMMIT — never squash)
                               │
                               ▼
 main ─ push ─▶ release.yml:  ci ──▶ release
                                       │  semantic-release: vX.Y.Z tag, GitHub Release,
                                       │  CHANGELOG.md + package.json, "chore(release) [skip ci]"
                                       └─ fast-forward dev ← main, even if the release failed
                                          (the App merges main into dev if dev moved meanwhile)
```

### Environments

`*.keimelion.zalbani.dev` is the **pre-prod**: every push to `dev` whose `CI` run is green is
deployed there.

`keimelion.app` is the **production**: every push to `main` whose `Release` run is green is
deployed there, even when no tag was created. `ci.yml` does not run on `main`: `Release` holds
its tests, and deploying after it includes the release commit. That commit carries `[skip ci]`,
so it starts no workflow; a deploy already at the tip of `main` skips its steps.
See the runbook, "Production stack".

The app repos' `deploy.yml` starts from `workflow_run` rather than being a job of `ci.yml`:
`ci.yml` cancels its in-progress run on every new push, which could stop a deploy in the
middle of a migration. A cancelled CI simply deploys nothing, and the next green push deploys
the tip of `dev`.

### Why a merge commit for the release PR

semantic-release reads the commits between the last tag and `main`. A merge commit
keeps every squashed feature commit of `dev`, so the bump and the CHANGELOG reflect
each PR. A squashed release PR would collapse them into one commit, and would make
`dev` and `main` diverge forever. Feature PRs into `dev` stay squashed (one PR = one
Conventional Commit, validated by `pr-title.yml` and, locally, by commitlint).

## Commit convention → version

The bump is **computed**, never chosen by hand: semantic-release
(`conventionalcommits` preset) takes the highest bump among the commits since the
last tag. With squash merges, "commit" = **PR title** + **PR description** (the squash
body): a `BREAKING CHANGE:` / `Breaking change:` line in a PR description counts too,
case-insensitive.

The apps are in **0.x** (not 1.0 yet): `.releaserc.json` maps breaking changes to a
**minor** bump (`releaseRules`). Going 1.0 is an explicit decision: remove that rule (the
next breaking change gives `1.0.0`) or tag `v1.0.0` by hand.

| PR title | Bump in 0.x | Example |
|---|---|---|
| `fix: …`, `perf: …`, `revert: …` | patch `0.3.1 → 0.3.2` | `fix: lists/:id 404 on archived list (KEI-150)` |
| `feat: …` | minor `0.3.1 → 0.4.0` | `feat: users/me/export CSV (KEI-37)` |
| `<type>!: …` or `BREAKING CHANGE:` footer | minor `0.3.1 → 0.4.0` (major after 1.0) | `feat!: drop /v0 routes (KEI-160)` |
| `chore`, `ci`, `docs`, `refactor`, `test`, `style`, `build` | none — no tag | `chore: bump deps` |

GitHub Releases are created without commenting the released PRs/issues
(`successComment: false`, `releasedLabels: false`).

- The release PR title doesn't matter (merge commits are ignored): use `chore: release`.
- The release commit is written by semantic-release: `chore(release): X.Y.Z [skip ci]`.
- To release a dependency bump or refactor anyway, title it `fix:` (or merge it with a
  `fix`/`feat` in the same release).

## npm package (Keimelion-SDK)

`@keimelion/sdk` is the single source of truth of the API contract (schemas, enums,
error codes, HTTP client), published **publicly** on npmjs. Same flow as the apps
(`dev` → release PR → `main` → semantic-release, 0.x rules above), then:

```
 main ─ push ─▶ release.yml:  ci ──▶ release ──▶ npm-publish (only if a tag was created)
                                                   checkout vX.Y.Z, npm ci, build,
                                                   publint + attw,
                                                   npm publish --provenance --access public
 dev ── push ─▶ release.yml:  ci ──▶ publish-dev
                                       npm ci, version <next release>-dev.<N>, build,
                                       npm publish --provenance --access public --tag dev
```

- `npm-publish.yml` is a **job of the same run** (`needs: release`,
  `if: needs.release.outputs.published == 'true'`, `with: version`), not a workflow on
  tag push: a tag pushed with `GITHUB_TOKEN` never triggers another workflow.
- `@semantic-release/npm` keeps `npmPublish: false` (it only bumps `package.json`);
  publishing happens in `npm-publish.yml` and `npm-publish-dev.yml`, the **only** jobs with
  publish rights (`id-token: write`). They skip what is already on npmjs, so a re-run is
  harmless: `npm-publish-dev.yml` recognizes a commit already published through `gitHead`.
- `npm-publish-dev.yml` publishes every push to `dev` on the `dev` dist-tag, so `latest` stays
  on the stable release. The base is the next release given the commits since the last stable
  tag (0.x table above, a `chore`/`ci`-only range counts as patch), and `N` restarts at 1 for
  each new base: `0.1.1-dev.1`, `0.1.1-dev.2`, then a `feat` gives `0.2.0-dev.1`. The version
  only exists in the runner (no commit, no tag). To test an
  unreleased contract: `npm install @keimelion/sdk@dev --save-exact`; a caret range never
  matches a prerelease. Go back to the stable version before releasing the consumer.
- Its job lives in the SDK's `release.yml`, next to `npm-publish`: the trusted publisher is
  bound to that filename, a separate caller workflow would be refused by npm.
- Auth: **npm Trusted Publishing** (OIDC, no long-lived token). The very first version
  can be published before a trusted publisher is attached to the package only with a
  token: a short-lived granular automation token as the `NPM_TOKEN` secret of the SDK
  repo **only**, then switch to OIDC and revoke the token (see one-time setup).
- The first release is `0.1.0`: the bootstrap commit of the SDK repo is tagged `v0.0.0`,
  so the first `feat:` on `main` bumps to `0.1.0` (without a tag semantic-release starts
  at `1.0.0`).
- Consumers need **no registry auth** (no `.npmrc` token, no Docker build secret, no
  Dependabot registry, no `packages: read`).
- **SDK first, then the API**: a change of an API request/response shape is released in
  the SDK first; the API PR then bumps `@keimelion/sdk`.

## Releasing

1. Open a PR `dev → main` titled `chore: release`, wait for CI.
2. **Merge with "Create a merge commit"**.
3. Watch the `Release` run: tag + GitHub Release, `dev` fast-forwarded.

Manual redeploy (e.g. after a server rebuild): `Deploy` workflow → *Run workflow*, choosing the stack.

## Versioning of the reusable workflows

### Tag scheme

Every change landing on `main` here gets a new immutable `vX.Y.Z` tag, created by
`.github/workflows/tag.yml` (the first one is `v0.1.0`). There is **no floating tag** (`v0`,
`v1`) and a tag is never moved: with a tag moved on every merge, one bad commit would still
reach every repo at once, and Dependabot would not see any update to propose.

### Bump rules

The bump is computed from the commits since the latest tag, with the 0.x policy of the apps.
Unlike the apps, **every** change is tagged, including `ci:` ones, which are most of the
changes here.

| Commits since the latest tag | Bump | Example |
|---|---|---|
| at least one `<type>!: …` or `BREAKING CHANGE:` footer | minor `0.1.4 → 0.2.0` | `ci!: rename the node-ci inputs` |
| at least one `feat: …` | minor `0.1.4 → 0.2.0` | `feat: npm-publish reusable workflow` |
| anything else | patch `0.1.4 → 0.1.5` | `ci: bump the runner timeout` |

Going 1.0 is an explicit decision: tag `v1.0.0` by hand and change the rule in `tag.yml` so
that a breaking change bumps the major.

### Rollout through Dependabot

1. A PR is merged on `main` here: `tag.yml` creates the tag. No app repo is affected.
2. On its next weekly run, Dependabot (`github-actions` ecosystem of `.github/dependabot.yml`)
   opens **one update PR per repo**. To get it sooner: *Insights → Dependency graph →
   Dependabot → Check for updates* in the app repo.
3. The PR is **reviewed and merged by hand**, one repo at a time if the change is risky.
   `dependabot-automerge.yml` never merges a Keimelion-Infra update, whatever its type: PR CI
   does not exercise release, deploy or npm-publish. The new pipeline is really exercised by
   the next release of that repo, so start with a repo that can afford a failed release.

Dependabot names a reusable workflow `Keimelion/Keimelion-Infra/.github/workflows/<file>.yml`,
that is one dependency per workflow file. The `keimelion-infra` group of `dependabot.yml`
brings them back into one PR, which also keeps every caller of a repo on the same tag.

An update PR left unmerged does not go stale: when a newer tag exists, the next Dependabot
run supersedes it (it closes the PR and opens one for the newest tag). There is nothing to
clean up, and a superseded version never has to be merged first.

### Testing a change before tagging

A tag is cut as soon as a PR is merged here, so test from the PR branch first:

1. In an app repo, create a throwaway branch and point the callers at the Infra branch:
   `uses: Keimelion/Keimelion-Infra/.github/workflows/<file>.yml@<infra-branch>`.
2. Open a **draft** PR from it and read the `CI` run. Only what `ci.yml` calls runs this way.
   `release.yml`, `deploy.yml`, `npm-publish.yml` and `npm-publish-dev.yml` run after a merge
   only, so review their changes by reading them.
3. **Never merge that PR.** Close it and delete the branch, then merge the Infra PR.

## One-time GitHub setup

- **Self-hosted runner on public repos**: org *Settings → Actions → General* →
  *Require approval for all external contributors* for fork PR workflows. A fork PR
  could otherwise add a job `runs-on: [self-hosted, keimelion]` and run code on
  milky-way. If the plan allows runner groups, restrict the `keimelion` runner to
  the `Keimelion-Infra/.github/workflows/deploy.yml` workflow.
- **Branches & merge methods** (all three app repos and the SDK): default branch `dev`; allow
  *squash* (feature PRs) **and** *merge commits* (release PRs).
- **Release GitHub App** `keimelion-release` (owned by the org, installed on the three
  app repos and the SDK): *Contents*, *Issues*, *Pull requests* read & write. Its credentials are the
  org secrets `RELEASE_APP_ID` / `RELEASE_APP_PRIVATE_KEY`; without them the release
  falls back to `GITHUB_TOKEN` (which cannot bypass rulesets).
- **npm** (SDK): org `keimelion` on npmjs owning the `@keimelion` scope (2FA enforced).
  First publish: either a trusted publisher can be added before the package exists, or
  bootstrap `0.1.0` with a granular automation token (`@keimelion/sdk` read & write, short
  expiry) as the `NPM_TOKEN` secret of Keimelion-SDK. Then on npmjs *@keimelion/sdk →
  Settings → Trusted Publisher*: GitHub Actions, `Keimelion/Keimelion-SDK`, workflow
  `release.yml`; set *Publishing access* to "Require two-factor authentication and
  disallow tokens", delete the `NPM_TOKEN` secret and revoke the token.
- **Rulesets** are versioned in `github/rulesets/<kind>/` and applied with
  `scripts/apply-rulesets.sh [repo...]` (create or update by name; needs repo admin):
  - `apps/` (API, Back-office, Landing, SDK) — `main`: PR required, **merge commit only**
    (release PRs); `dev`: **squash only** (feature PRs); both require
    the `ci` + `pr-title` checks; the release App is the only bypass actor (release commit
    + tag on `main`, fast-forward of `dev`, or merge of `main` into `dev` if it moved)
  - `infra/` (this repo) — `main`: PR required, squash only, `actionlint` check, no bypass
    (every tag the app pipelines pin is cut from `main`)
  - `collections/` (Keimelion-API-collections) — `main`: no deletion, no force-push
  - all: no deletion, no force-push
