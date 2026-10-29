# Runbook — serveur Keimelion

## Démarrer / arrêter la stack

## Consulter les logs

## Déployer une nouvelle version

## Migrations de base de données

## Seed de la base

## Backup Postgres

## Restauration Postgres

## Rotation des secrets

## Reboot et vérifications post-reboot

## Incidents connus

## NEXT_PUBLIC_API_URL figée au build

`NEXT_PUBLIC_API_URL` est injectée dans le bundle du back-office au build. Changer de domaine (ex. passage à `api.keimelion.app` en prod) impose un rebuild de l'image `back` avec la nouvelle URL en argument de build.

## Redirection langue Landing

La redirection vers `/en/` selon la langue du navigateur (définie dans `vercel.json`) n'est pas active dans l'image Docker. À reporter dans le Caddyfile lors de l'exposition à internet.

## Accéder à la DB depuis une station de dev

Postgres n'écoute que sur `127.0.0.1:5432` du serveur : passer par un tunnel SSH (`ssh -L 5433:localhost:5432 milky-way -N`) puis se connecter à `postgres://keimelion:<POSTGRES_PASSWORD>@localhost:5433/keimelion`. Le tunnel est authentifié par la clé SSH : inutile d'ouvrir 5432 sur le pare-feu.
