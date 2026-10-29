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
│   │   ├── postgres/
│   │   └── uploads/
│   ├── caddy/
│   ├── scripts/
│   └── docs/runbook.md
├── Keimelion-API/            ← git@github.com:Keimelion/Keimelion-API.git        (dev)
├── Keimelion-Backoffice/     ← git@github.com:Keimelion/Keimelion-Backoffice.git (dev)
└── Keimelion-Landing/        ← git@github.com:Keimelion/Keimelion-Landing.git    (main)
```

Build paths in `docker-compose.yml` are relative (`../Keimelion-API`, …):
the folder names above must be kept as is.

## Initial setup

```bash
cd ~/keimelion
git clone git@github.com:Keimelion/Keimelion-Infra.git
git clone -b dev git@github.com:Keimelion/Keimelion-API.git
git clone -b dev git@github.com:Keimelion/Keimelion-Backoffice.git
git clone git@github.com:Keimelion/Keimelion-Landing.git

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
```

Drizzle migrations are applied automatically when the API starts.
The seed is **never** run automatically (see the runbook).

## Updating

```bash
cd ~/keimelion
for r in Keimelion-API Keimelion-Backoffice Keimelion-Landing Keimelion-Infra; do git -C "$r" pull --ff-only; done
cd Keimelion-Infra
docker compose up -d --build
```

## Services

| Service   | Host port              | Image / build             |
|-----------|------------------------|---------------------------|
| postgres  | 127.0.0.1:5432         | postgres:17-alpine        |
| api       | 127.0.0.1:${API_PORT}  | ../Keimelion-API          |
| back      | 127.0.0.1:${BACK_PORT} | ../Keimelion-Backoffice   |
| landing   | 127.0.0.1:${LANDING_PORT}| ../Keimelion-Landing      |
| caddy     | 0.0.0.0:80             | caddy:2-alpine            |

Caddy is the LAN entry point (plain HTTP, no ACME yet), routing by hostname:
`keimelion.local` → landing, `admin.keimelion.local` → back-office,
`api.keimelion.local` → API (+ `/uploads/*` served from `data/uploads`).
The other ports are debug-only, bound to loopback (see the runbook, "Networking & firewall").

All services use `restart: unless-stopped` and Docker is enabled at boot
(`systemctl is-enabled docker`): a reboot brings everything back up.

## Postgres backup

TODO — scheduled dump (`pg_dump` via `docker compose exec postgres`), retention, off-machine copy.

## See also

- [docs/runbook.md](docs/runbook.md) — operating procedures
