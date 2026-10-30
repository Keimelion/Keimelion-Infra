# Runbook — Keimelion server

## Setup from scratch

Follow the README "Initial setup". Run `scripts/setup-data-dirs.sh` (with `sudo` if `data/` already exists and is owned by root) before the first `docker compose up`.

## Start / stop the stack

```bash
cd ~/keimelion/Keimelion-Infra
docker compose up -d           # start everything
docker compose down            # stop (containers + network, keeps volumes)
docker compose restart caddy   # restart one service
docker compose ps              # see what's running
```

Services use `restart: unless-stopped` and Docker is enabled at boot: a reboot
brings everything back up.

## Check the logs

```bash
docker compose logs -f api            # follow one service
docker compose logs --tail=200 caddy  # last 200 lines (includes access logs
                                      # for *.keimelion.zalbani.dev, see Caddyfile)
docker compose logs                   # everything, from the beginning
```

Caddy writes an access log for each public hostname (the `log` directive in
`caddy/Caddyfile`). Lines look like `host="keimelion.zalbani.dev" status=200
remote_ip=192.168.1.100 …`, where `remote_ip` is the NAS reverse-proxy
address (TLS was terminated upstream).

## Deploy a new version

Manual deploy (CI with rollback is in the backlog):

```bash
cd ~/keimelion
# Pull the ONE repo you want to deploy; e.g. the API dev branch:
git -C Keimelion-API pull --ff-only
cd Keimelion-Infra
docker compose up -d --build api  # or back / landing / caddy
```

Reload Caddy after editing `caddy/Caddyfile` **without** restarting the
container (zero downtime):

```bash
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

The whole `caddy/` folder is bind-mounted (not just the file), so edits land
in the container through the host, and `caddy reload` picks them up.

## Database migrations

## Seeding the database

Dev/test data only, never in production. The API image does not ship `src/db/seed`, so run the compiled seed in a one-off container with the fixtures mounted read-only (seeders are idempotent):

```bash
docker compose run --rm --no-deps \
  -v ../Keimelion-API/src/db/seed/fixtures:/app/src/db/seed/fixtures:ro \
  api node dist/db/seed/index.js
```

## Postgres backup

## Postgres restore

Disaster recovery on a fresh machine: run `scripts/setup-data-dirs.sh` before starting the stack, then restore the dump.

## Secret rotation

## Reboot and post-reboot checks

## Known incidents

## NEXT_PUBLIC_API_URL is baked in at build time

`NEXT_PUBLIC_API_URL` (and the landing's `PUBLIC_API_BASE_URL`) is inlined
into the browser bundle at build time. Changing `PUBLIC_API_URL` in `.env`
requires `docker compose up -d --build back landing` for the new value to
reach the browser.

## Landing language redirect

The redirect to `/en/` based on the browser language (defined in `vercel.json`) is not active in the Docker image. Port it to the Caddyfile when exposing to the internet.

## Networking & firewall

- Docker publishes ports through its own iptables rules (NAT + `FORWARD` chain, filterable only in `DOCKER-USER`), not through `INPUT`: **UFW rules do not apply to published ports**.
- Debug ports (api 3000, back 3001, landing 3002, postgres 5432) are deliberately bound to `127.0.0.1`: reach them through an SSH tunnel from a dev workstation.
- Caddy on `:80` is bound to `0.0.0.0`. It is the only entry point from the LAN **and** from the NAS reverse proxy, routing by `Host` header (see "Cloudflare / NAS exposure" and "Access from a LAN client"). UFW is currently **inactive**.
- The home router forwards `:80` and `:443` to the Synology NAS (`192.168.1.100`), which handles TLS for `*.zalbani.dev`. No port is forwarded directly to milky-way (`192.168.1.102`).

## Cloudflare / NAS exposure

The public hostnames follow the same rail as `ha.zalbani.dev` and
`seerr.zalbani.dev` — no Cloudflare Tunnel, no local ACME. Managed outside
this repo (dashboard, not Git) because the setup predates the project:

1. **Cloudflare DNS** (`zalbani.dev` zone, Cloudflare-managed nameservers):
   three `DNS only` CNAMEs → `backward.zalbani.dev` (A record pointing to the
   home public IP, kept fresh by the Home Assistant Cloudflare DDNS plugin).
   | Record                        | Target                 |
   |-------------------------------|------------------------|
   | keimelion.zalbani.dev         | backward.zalbani.dev   |
   | admin.keimelion.zalbani.dev   | backward.zalbani.dev   |
   | api.keimelion.zalbani.dev     | backward.zalbani.dev   |

2. **Home router port forwards**: `80/tcp` and `443/tcp` → `192.168.1.100` (NAS).

3. **Synology DSM → Control Panel → Login Portal → Advanced → Reverse Proxy**:
   three entries, all HTTPS :443 (source) → HTTP `192.168.1.102:80` (destination,
   milky-way LAN IP). "Create → WebSocket" preset enabled so `Upgrade` /
   `Connection` headers pass through. DSM preserves the original `Host`
   header (nginx `proxy_set_header Host $host`), which lets Caddy dispatch.

4. **Synology DSM → Control Panel → Security → Certificate**: one Let's
   Encrypt certificate per public hostname (HTTP-01 challenge, served by DSM
   on :80). Each cert is assigned to its reverse-proxy service in
   `Certificate → Settings`.

Rolling out a new public hostname is three steps outside this repo (CNAME +
reverse-proxy entry + cert) and one block in `caddy/Caddyfile` + `up -d
caddy` + `caddy reload`.

## Access from a LAN client

The stack is reachable in two ways from the LAN:

- Through the public hostnames, if the home router does NAT loopback
  (hairpin): https://keimelion.zalbani.dev etc. resolve via Cloudflare and
  bounce back inside. This has been verified on the current router.
- Plain-HTTP LAN fallback (useful for low-level debug, or when the NAS
  reverse proxy is down). Add this line to `/etc/hosts` on each client:
  ```
  192.168.1.102   keimelion.local admin.keimelion.local api.keimelion.local
  ```
  Then: http://keimelion.local, http://admin.keimelion.local,
  http://api.keimelion.local. http://192.168.1.102 redirects to the landing.
  Caveat: the front-end bundles call `https://api.keimelion.zalbani.dev`
  (baked at build time), and the API's CORS allow-list does not include the
  `.local` origins, so opening a front via `.local` from a browser gives a
  working shell but failing XHR. Use `.local` for curl-level checks only.

## Accessing the DB from a dev workstation

The DB is not routed through Caddy. Postgres only listens on the server's `127.0.0.1:5432`: open an SSH tunnel (`ssh -L 5433:localhost:5432 milky-way -N`), then connect to `postgres://keimelion:<POSTGRES_PASSWORD>@localhost:5433/keimelion`. The tunnel is authenticated by your SSH key: no need to open 5432 on the firewall.
