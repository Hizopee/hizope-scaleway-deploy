# Lazulitteraire sur la VPS partagée

Révisions du CAPES de lettres modernes : **https://revision.hizope.fr**
(dépôt `Hizopee/Lazulitteraire` : API .NET + site Vue, application Flutter à part).

| | |
|---|---|
| Conteneurs | `lazulitteraire-api` (API, PostgreSQL) et `lazulitteraire-web` (nginx : site Vue, relaie `/api`) |
| Images | `ghcr.io/hizopee/lazulitteraire-api:main` et `…-web:main`, construites sur GitHub |
| Base | `revision` (rôle `revision_app`) sur le Postgres de la VPS, sauvegardée chaque nuit |
| Domaine | `revision.hizope.fr` (Caddy, certificat automatique) |
| Déploiement | automatique à chaque push sur `main` du dépôt (`.github/workflows/docker.yml`) |

## Mise en place (une seule fois)

L'ordre compte : le premier déploiement automatique échoue tant que les étapes 1 à 4 ne sont pas faites.

### 1. DNS

Chez le gestionnaire DNS de `hizope.fr` : enregistrement **A** `revision` → `62.210.78.72`.

### 2. Base de données

Le script `postgres/init/01-create-databases.sh` ne tourne qu'à la création du volume : la base est
donc ajoutée à la main sur le Postgres existant.

```bash
cd ~/hizope-scaleway-deploy/shared-vps
PGPASS=$(openssl rand -hex 24); echo "$PGPASS"   # à noter pour l'étape 3
docker compose -f docker-compose.prod.yml exec -T postgres psql -U postgres <<SQL
CREATE ROLE revision_app LOGIN PASSWORD '$PGPASS';
CREATE DATABASE revision OWNER revision_app;
REVOKE ALL ON DATABASE revision FROM PUBLIC;
SQL
```

Les tables sont créées par l'API au premier démarrage.

### 3. Variables du `.env` de la VPS

Dans `~/hizope-scaleway-deploy/shared-vps/.env`, renseigner (voir `.env.example`) :
`REVISION_PG_PASSWORD` (la valeur de l'étape 2), `REVISION_DB_CONNECTION` (même mot de passe),
`REVISION_AUTH_SECRET` (`openssl rand -base64 48`) et, si on veut « Contester la correction »,
`REVISION_ANTHROPIC_API_KEY`.

Une seule ligne par variable : vérifier avec `grep -n '^REVISION_' .env` (une ligne en double, vide, écrase
la bonne et le conteneur démarre sans le secret).
`REVISION_AUTH_SECRET` est à conserver : le changer invalide tous les codes d'accès.

### 4. Mettre à jour le dépôt d'infra sur la VPS

Après le merge de la PR d'infra :

```bash
cd ~/hizope-scaleway-deploy && git pull
```

### 5. Secret du dépôt GitHub

Le dépôt `Hizopee/Lazulitteraire` a besoin du secret `DEPLOY_SSH_KEY` (même clé de déploiement que les
autres dépôts), pour que le workflow se connecte à la VPS.

### 6. Premier déploiement, puis Caddy

Lancer le workflow « Images Docker » du dépôt (onglet Actions → Run workflow), ou pousser sur `main` : il construit
les deux images puis les déploie. Ensuite, recharger Caddy une fois pour prendre en compte le nouveau domaine :

```bash
cd ~/hizope-scaleway-deploy/shared-vps
docker compose -f docker-compose.prod.yml exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Vérification : `https://revision.hizope.fr/api/health` doit répondre `{"ok":true}`.

## Au quotidien

- Une modification mergée sur `main` est déployée toute seule (images reconstruites, conteneurs relancés).
- Journaux : `docker compose -f docker-compose.prod.yml logs --tail 100 lazulitteraire-api`.
- Retour arrière : relancer le workflow sur le commit précédent, ou, à la main sur la VPS, mettre le tag
  `:<sha>` de l'image voulue dans le compose.
