# Keimelion-Infra

Versioned, reproducible configuration of the Keimelion home server (`milky-way`):
Postgres + API + Back-office + Landing orchestrated by Docker Compose, restarted
automatically on boot.

This repo contains **no application code** and **no secrets**: it references the
sibling repos cloned next to it and reads its secrets from a local, unversioned `.env`.

## Prerequisites

- Debian 13 (trixie)
- Docker Engine + Compose plugin, installed from the official Docker repository
  (https://docs.docker.com/engine/install/debian/) — not Debian's `docker.io` package
- User in the `docker` group
- SSH key authorized on the `Keimelion` GitHub organization
- Sibling repos cloned in `~/keimelion/` (see layout below)

## Expected layout on disk

```
~/keimelion/
├── Keimelion-Infra/          ← this repo
│   ├── docker-compose.yml
│   ├── .env                  ← local secrets (gitignored)
│   ├── .env.example
│   ├── data/                 ← persistent volumes (gitignored)
│   │   ├── postgresql/       ← Postgres 18+ (18/docker/ = PGDATA)
│   │   └── uploads/
│   ├── secrets/              ← restic password (gitignored, copy in the password manager)
│   ├── caddy/
│   ├── scripts/              ← scripts/backup/: backup, restore, restore test
│   ├── systemd/              ← backup units + timers (installed by scripts/backup/install.sh)
│   └── docs/
├── Keimelion-API/            ← git@github.com:Keimelion/Keimelion-API.git        (dev)
├── Keimelion-Backoffice/     ← git@github.com:Keimelion/Keimelion-Backoffice.git (dev)
└── Keimelion-Landing/        ← git@github.com:Keimelion/Keimelion-Landing.git    (dev)
```

Build paths in `docker-compose.yml` are relative (`../Keimelion-API`, …):
the folder names above must be kept as is.

## Initial setup

```bash
cd ~/keimelion
git clone git@github.com:Keimelion/Keimelion-Infra.git
git clone -b dev git@github.com:Keimelion/Keimelion-API.git
git clone -b dev git@github.com:Keimelion/Keimelion-Backoffice.git
git clone -b dev git@github.com:Keimelion/Keimelion-Landing.git

cd Keimelion-Infra
cp .env.example .env
chmod 600 .env
# Edit .env: generate POSTGRES_PASSWORD (openssl rand -hex 32),
# JWT_SECRET (openssl rand -base64 48), set PUBLIC_API_URL / CORS_ORIGINS to the server IP
# Create data/ dirs with the right ownership BEFORE the first `up` (otherwise Docker
# creates them as root and the API, running as uid 1000, cannot write uploads)
scripts/setup-data-dirs.sh
docker compose up -d --build
docker compose ps
# Backups: see docs/backup.md "One-time setup"
sudo scripts/backup/install.sh && scripts/backup/init-repos.sh
```

Drizzle migrations are applied automatically when the API starts.
The seed is **never** run automatically (see the runbook).

### Transactional email

The API reads these variables from `.env` (the `api` service loads it through `env_file`):

| Variable | Role |
|---|---|
| `EMAIL_PROVIDER` | Mail adapter used by the API (default: `resend`) |
| `EMAIL_API_KEY` | Provider API key. Secret: never commit or log it |
| `EMAIL_FROM` | Sender address, on `keimelion.app` |

With `NODE_ENV=production`, a send fails and logs an error if `EMAIL_API_KEY` or
`EMAIL_FROM` is empty. Outside production, emails are written to the API log.

## Updating

Automatic, through GitHub Actions on the self-hosted runner (health check + rollback):

- **App repos**: a push to `dev` with a green CI run deploys that service to the pre-prod, a
  push to `main` with a green Release run deploys it to the production (reusable workflows of
  this repo, see [docs/release-process.md](docs/release-process.md)).
- **This repo**: every merge on `main` runs `deploy-infra.yml`, which for the pre-prod and
  then the production pulls the stack's checkout, runs `docker compose up -d --no-build` (recreates only
  the services whose config changed) and reloads Caddy when its config changed. It refuses
  to run if tracked files were edited by hand on the server. `.env` changes are not in
  git: apply them by hand (`docker compose up -d`).

Manual fallback (runner down), pulling every repo and rebuilding what changed:

```bash
cd ~/keimelion
for r in Keimelion-API Keimelion-Backoffice Keimelion-Landing Keimelion-Infra; do git -C "$r" pull --ff-only; done
cd Keimelion-Infra
docker compose up -d --build
```

## Public exposure

The stack is reachable at:

- https://keimelion.zalbani.dev           (landing)
- https://admin.keimelion.zalbani.dev     (back-office)
- https://api.keimelion.zalbani.dev       (API + `/uploads/*`)

Flow: Cloudflare DNS (CNAME → `backward.zalbani.dev`) → home router (:443 and
:80 forwarded to the NAS) → Synology reverse proxy (TLS, Let's Encrypt
HTTP-01) → `http://192.168.1.102:80` → Caddy on milky-way. The NAS, DNS
records and reverse-proxy entries are configured outside this repo
(dashboard-managed); see `docs/runbook.md`, "Cloudflare / NAS exposure".

This is the pre-prod. The production runs on `keimelion.app` through Caddy on `:8080`, see
`docs/runbook.md`, "Production stack".

## Services

| Service   | Host port              | Image / build             |
|-----------|------------------------|---------------------------|
| postgres  | 127.0.0.1:5432         | postgres:18.6-alpine      |
| api       | 127.0.0.1:${API_PORT}  | ../Keimelion-API          |
| back      | 127.0.0.1:${BACK_PORT} | ../Keimelion-Backoffice   |
| landing   | 127.0.0.1:${LANDING_PORT}| ../Keimelion-Landing      |
| caddy     | 0.0.0.0:80             | caddy:2-alpine            |

Caddy routes by hostname and stays in plain HTTP. TLS for `*.keimelion.zalbani.dev`
is terminated upstream by the Synology NAS (reverse proxy + Let's Encrypt), which
forwards to `http://192.168.1.102:80` where Caddy dispatches to `landing:3002`,
`back:3001` or `api:3000` (+ `/uploads/*` served from `data/uploads`). LAN hostnames
`*.keimelion.local` are kept as a plain-HTTP fallback via `/etc/hosts`.
The debug ports (api/back/landing/postgres) are bound to loopback — see the runbook
("Networking & firewall", "Access from a LAN client").

All services use `restart: unless-stopped` and Docker is enabled at boot
(`systemctl is-enabled docker`): a reboot brings everything back up.

## Backups

Postgres, `data/uploads` and `.env` are backed up with restic every 6 hours and before
every deploy, copied to the Synology NAS, and restored into a throwaway Postgres every
week to prove the backups work (Uptime Kuma push monitors alert on a failure or a missing run).
Setup, restore procedures and disaster recovery: [docs/backup.md](docs/backup.md).

## See also

- [docs/runbook.md](docs/runbook.md) — operating procedures
- [docs/backup.md](docs/backup.md) — backup, restore, disaster recovery
- [docs/release-process.md](docs/release-process.md) — CI, release & deploy
