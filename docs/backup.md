# Backup & restore

Everything the Keimelion stack cannot rebuild from git — the Postgres database, the
uploaded images and the server `.env` — is backed up with [restic](https://restic.net)
(encrypted, deduplicated, checksummed) and restored automatically every week to prove it
works.

| | |
|---|---|
| **RPO** (max data loss) | 6 h — 0 for a deploy (snapshot taken right before) |
| **RTO** (restore time) | ~15 s at the current size (measured by every restore test, see its log) |
| **Copies** | live data + local repository (`/var/backups/keimelion`) + Synology NAS (SFTP) |
| **Alerting** | Uptime Kuma push monitors (on the NAS): a failure **or a missing run** sends an alert |

```
                 every 6 h / before each deploy                      weekly (Sun 04:45)
 postgres ──pg_dump──▶ staging/ ─┐                       ┌──────────────────────────────┐
 data/uploads ───────────────────┼─▶ restic (local) ──copy──▶ restic (NAS) ──restore──▶ throwaway
 .env ───────────────────────────┘   forget/prune         forget/prune     Postgres + row-count diff
```

## What a snapshot contains

| Path in the snapshot | Content |
|---|---|
| `…/staging/db/keimelion.dump` | `pg_dump --format=custom` of the database |
| `…/staging/db/globals.sql` | roles (`pg_dumpall --globals-only`, without passwords) |
| `…/staging/db/rowcounts.tsv` | exact row count of every table, **taken in the dump's own transaction snapshot** |
| `…/staging/manifest.env` | date, tag, Postgres version + image, Infra/API commits, dump size + sha256 |
| `…/Keimelion-Infra/data/uploads/` | uploaded images |
| `…/Keimelion-Infra/.env` | server secrets (needed to rebuild the server; the repository is encrypted) |

Snapshots are tagged with why they were taken: `scheduled`, `pre-deploy` (+ `api` for the
API deploy's), `pre-restore`, `manual`. Retention (`BACKUP_RETENTION`) applies per tag: by default the last 4, then one
per day for 14 days, per week for 8 weeks, per month for 12 months.

## Jobs

| systemd unit | When | Script | Monitoring |
|---|---|---|---|
| `keimelion-db-backup.timer` → `keimelion-db-backup@scheduled` | 00:15, 06:15, 12:15, 18:15 (± 5 min, caught up at boot) | `db-backup.sh scheduled` | `HC_BACKUP_URL` |
| `keimelion-db-backup@pre-deploy-api` | `deploy.yml` (API), before the migrations; ID recorded for the rollback | `db-backup.sh pre-deploy-api` | — (fails the deploy) |
| `keimelion-db-backup@pre-deploy` | `deploy-infra.yml`, before `up -d` | `db-backup.sh pre-deploy` | — (fails the deploy) |
| `keimelion-db-restore@pre-deploy-api` | `deploy.yml` rollback, only if the previous release fails on the migrated schema | `db-restore.sh --last pre-deploy-api --yes` | — (job annotations) |
| `keimelion-backup-verify.timer` | Sundays 04:45 | `backup-verify.sh` | `HC_VERIFY_URL` |

`db-backup.sh` fails the scheduled run if the off-site copy fails; for `pre-deploy` the
off-site copy is best effort (a NAS outage must not block deploys, the next scheduled run
copies the snapshot).

`backup-verify.sh` (production is never touched):
1. `restic check --read-data-subset=10%` on both repositories (the whole data is read
   about every 10 weeks);
2. restores the latest snapshot **from the NAS** with `restic restore --verify`;
3. fails if it is older than `BACKUP_MAX_AGE_HOURS` (12 h) or if the dump sha256 differs
   from the manifest;
4. `pg_restore --exit-on-error --single-transaction` into a throwaway container running the
   same image as production, without network;
5. compares every table's row count with `rowcounts.tsv`: a single row of difference fails.

## One-time setup

1. **System part** (restic package, `/var/backups/keimelion`, systemd units + timers,
   sudoers rule for the GitHub runner), from the deploy checkout:
   ```bash
   cd ~/keimelion-integration/Keimelion-Infra
   sudo scripts/backup/install.sh
   ```
2. **NAS** (DSM):
   - Control Panel → File Services → FTP → **SFTP: enable** (port 22).
   - Control Panel → Shared Folder → create `keimelion-backup` (recycle bin off: restic
     manages its own deletions).
   - Snapshot Replication → Snapshots → `keimelion-backup`: daily snapshot, keep 30.
     The server's SFTP key can delete the repository (`forget --prune` needs write
     access): read-only Btrfs snapshots are what survives a compromised server or a
     ransomware.
   - Control Panel → User → create `keimelion-backup`, read/write **only** on that
     shared folder, deny every application except SFTP. Enable "User home service"
     (Control Panel → User → Advanced) so the key can be installed.
   - Install the server's public key `~/.ssh/keimelion-backup_ed25519.pub` in
     `/homes/keimelion-backup/.ssh/authorized_keys` (permissions 700/600).
   - Check from milky-way: `ssh keimelion-nas` must open an SFTP session (the alias is in
     `~/.ssh/config`), then `sftp keimelion-nas:/keimelion-backup` lists the folder.
3. **Repositories**, as the backup user:
   ```bash
   scripts/backup/init-repos.sh
   ```
   It generates `secrets/restic-password` if missing. **Copy it into the password manager
   immediately** (entry "Keimelion restic"): it is the only key to the backups, and it is
   lost with the server.
4. **Monitoring**: in Uptime Kuma, create two **Push** monitors and paste their push URLs
   into `.env` (the `?status=…` part is ignored, the scripts send `status=up|down` and a
   one-line message: the duration, or the error):
   - `Keimelion backup`: heartbeat interval 25200 s (6 h + 1 h) → `HC_BACKUP_URL`
   - `Keimelion backup verify`: heartbeat interval 691200 s (7 d + 1 d) → `HC_VERIFY_URL`

   Healthchecks.io URLs work too (`/start`, `/fail` and the log tail are sent). It is hosted
   outside the house: the only option that still alerts when the NAS, which runs Kuma
   and holds the off-site copy, is down.
5. **First run**, then check both monitors went green:
   ```bash
   sudo systemctl start --wait keimelion-db-backup@manual.service
   sudo systemctl start --wait keimelion-backup-verify.service
   journalctl -u 'keimelion-*' -n 50
   ```

The production stack repeats these steps from its own checkout. `BACKUP_ROOT`,
`RESTIC_PASSWORD_FILE` and `RESTIC_OFFSITE_REPOSITORY` in its `.env` point to its own
repositories, and `BACKUP_UNIT_PREFIX` gives it its own units, timers (shifted by
`BACKUP_ON_CALENDAR` / `VERIFY_ON_CALENDAR`) and sudoers file: replace `keimelion-` with
`keimelion-prod-` in the commands below. Its password goes in its own password manager entry.

## Day-to-day

```bash
systemctl list-timers 'keimelion-*'                       # next runs
journalctl -u keimelion-db-backup@scheduled -n 30         # last backup logs
journalctl -u keimelion-backup-verify -n 30               # last restore test
sudo systemctl start --wait keimelion-db-backup@manual    # backup now (e.g. before a manual operation)

# restic by hand (as the backup user)
export RESTIC_PASSWORD_FILE=~/keimelion-integration/Keimelion-Infra/secrets/restic-password
restic -r /var/backups/keimelion/restic snapshots
restic -r sftp:keimelion-nas:/keimelion-backup/restic snapshots
restic -r /var/backups/keimelion/restic dump latest /var/backups/keimelion/staging/manifest.env
```

## Restore

All scenarios start from `cd ~/keimelion-integration/Keimelion-Infra`.

### A. Bad migration / bad data, server OK

Restore the snapshot taken before the faulty deploy (or any earlier one):

```bash
restic -r /var/backups/keimelion/restic snapshots --tag pre-deploy   # pick the ID
scripts/backup/db-restore.sh --snapshot <ID>          # add --from offsite to read from the NAS
```

The script restores the snapshot, checks its sha256, shows what it is about to do and asks
for the database name. Then it takes a `pre-restore` snapshot of the current state,
restores into `keimelion_restore` **next to** the live database and checks the row counts.
Only then does it stop the API, swap the databases by renaming them (the live one
becomes `keimelion_pre_restore_<timestamp>`), restart the API and wait for `/health`.
Downtime is limited to the swap. The API reapplies the migrations newer than the
snapshot on start: to also go back in code, redeploy the previous API release first.

`--with-uploads` also copies back the images missing from `data/uploads` (it never
overwrites nor deletes a file).

**Rolling back a restore**: the previous database is kept, the script prints the exact
commands (stop the API, rename the databases back, start the API). Once satisfied:

```bash
docker compose exec postgres dropdb -U keimelion keimelion_pre_restore_<timestamp>
```

### B. Recover a few rows / one table

Never restore the whole base for that. Restore the snapshot elsewhere and copy what is
needed:

```bash
export RESTIC_PASSWORD_FILE=secrets/restic-password
restic -r /var/backups/keimelion/restic restore <ID> --target /var/backups/keimelion/work/manual \
  --include '**/staging/db'
dump=$(find /var/backups/keimelion/work/manual -name keimelion.dump)
docker compose exec postgres createdb -U keimelion keimelion_recovery
docker compose exec -T postgres pg_restore -U keimelion -d keimelion_recovery <"$dump"
# query keimelion_recovery, copy the rows into keimelion, then:
docker compose exec postgres dropdb -U keimelion keimelion_recovery
rm -rf /var/backups/keimelion/work/manual
```

### C. Server or disk lost (disaster recovery)

Needs: the NAS and the restic password (password manager).

1. New Debian 13 machine: Docker, user in the `docker` group, clone the four repos as in
   the README "Initial setup", **without** starting the stack.
2. Install restic, restore the server key for the NAS (or generate a new one and authorise
   it on the NAS), recreate the `keimelion-nas` alias in `~/.ssh/config`.
3. Get the `.env` and the uploads back from the NAS:
   ```bash
   cd ~/keimelion-integration/Keimelion-Infra
   mkdir -p secrets && (umask 077; cat >secrets/restic-password)   # paste the password, Ctrl-D
   export RESTIC_PASSWORD_FILE=$PWD/secrets/restic-password
   restic -r sftp:keimelion-nas:/keimelion-backup/restic restore latest --host keimelion --target /tmp/dr
   cp /tmp/dr/home/*/keimelion-integration/Keimelion-Infra/.env .env && chmod 600 .env
   sudo scripts/setup-data-dirs.sh
   cp -a /tmp/dr/home/*/keimelion-integration/Keimelion-Infra/data/uploads/. data/uploads/
   ```
   (adapt `BACKUP_ROOT`, `RESTIC_PASSWORD_FILE` in `.env` if the paths changed)
4. Start the stack (`docker compose up -d --build`): the API creates an empty schema.
5. `sudo scripts/backup/install.sh`, then
   `scripts/backup/init-repos.sh` (keeps the NAS repository, creates a new local one) and
   `scripts/backup/db-restore.sh --from offsite --skip-safety-backup`.
6. Check the public URLs, then `sudo systemctl start --wait keimelion-backup-verify`.

## Limits and next steps

- **NAS in the same house**: a fire or burglary takes both copies. Next step: a Hyper
  Backup task on the NAS pushing `keimelion-backup` to a cloud (Synology C2, Backblaze
  B2…) — the restic data is already encrypted, the cloud never sees plaintext.
- **RPO 6 h**: enough at this scale. Below that, move to continuous WAL archiving
  (pgBackRest / WAL-G, point-in-time recovery).
- **Data checksums** are on since the Postgres 18 cluster (default of `initdb` in 18): a
  corrupted page fails the read instead of returning wrong data, and the weekly restore
  test reads every row.
