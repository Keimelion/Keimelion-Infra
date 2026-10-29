# Keimelion-Infra

Configuration du serveur home Keimelion (`milky-way`), versionnée et reproductible :
Postgres + API + Back-office + Landing orchestrés par Docker Compose, redémarrage
automatique au boot.

Ce repo ne contient **aucun code applicatif** ni **aucun secret** : il référence les
repos frères clonés à côté de lui et lit ses secrets dans un `.env` local non versionné.

## Prérequis

- Debian 13 (trixie)
- Docker Engine + plugin Compose, installés depuis le dépôt officiel Docker
  (https://docs.docker.com/engine/install/debian/) — pas le paquet `docker.io` de Debian
- Utilisateur dans le groupe `docker`
- Clé SSH autorisée sur l'organisation GitHub `Keimelion`
- Les repos frères clonés dans `~/keimelion/` (voir arborescence ci-dessous)

## Arborescence attendue sur disque

```
~/keimelion/
├── Keimelion-Infra/          ← ce repo
│   ├── docker-compose.yml
│   ├── .env                  ← secrets locaux (gitignored)
│   ├── .env.example
│   ├── data/                 ← volumes persistants (gitignored)
│   │   ├── postgres/
│   │   └── uploads/
│   ├── caddy/
│   ├── scripts/
│   └── docs/runbook.md
├── Keimelion-API/            ← git@github.com:Keimelion/Keimelion-API.git        (dev)
├── Keimelion-Backoffice/     ← git@github.com:Keimelion/Keimelion-Backoffice.git (dev)
└── Keimelion-Landing/        ← git@github.com:Keimelion/Keimelion-Landing.git    (main)
```

Les chemins de build dans `docker-compose.yml` sont relatifs (`../Keimelion-API`, …) :
les noms de dossiers ci-dessus doivent être respectés.

## Setup initial

```bash
cd ~/keimelion
git clone git@github.com:Keimelion/Keimelion-Infra.git
git clone -b dev git@github.com:Keimelion/Keimelion-API.git
git clone -b dev git@github.com:Keimelion/Keimelion-Backoffice.git
git clone git@github.com:Keimelion/Keimelion-Landing.git

cd Keimelion-Infra
cp .env.example .env
chmod 600 .env
# Éditer .env : générer POSTGRES_PASSWORD (openssl rand -hex 32),
# JWT_SECRET (openssl rand -base64 48), ajuster PUBLIC_API_URL / CORS_ORIGINS à l'IP du serveur
docker compose up -d --build
docker compose ps
```

Les migrations Drizzle sont appliquées automatiquement au démarrage de l'API.
La seed (`npm run db:seed`) n'est **jamais** lancée automatiquement.

## Mise à jour

```bash
cd ~/keimelion
for r in Keimelion-API Keimelion-Backoffice Keimelion-Landing Keimelion-Infra; do git -C "$r" pull --ff-only; done
cd Keimelion-Infra
docker compose up -d --build
```

## Services

| Service   | Port hôte              | Image / build             |
|-----------|------------------------|---------------------------|
| postgres  | 127.0.0.1:5432         | postgres:17-alpine        |
| api       | 0.0.0.0:${API_PORT}    | ../Keimelion-API          |
| back      | 0.0.0.0:${BACK_PORT}   | ../Keimelion-Backoffice   |
| landing   | 0.0.0.0:${LANDING_PORT}| ../Keimelion-Landing      |

Tous les services sont en `restart: unless-stopped` et Docker est activé au boot
(`systemctl is-enabled docker`) : un reboot relance tout.

## Backup Postgres

TODO — dump planifié (`pg_dump` via `docker compose exec postgres`), rétention, copie hors machine.

## Voir aussi

- [docs/runbook.md](docs/runbook.md) — procédures d'exploitation
