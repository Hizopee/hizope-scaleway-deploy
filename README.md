# Déploiement Scaleway — Gaia + CMicrolocks (+ LoveList) — ~€53.60/mois

Gaia est hébergée sur sa propre VPS, séparée de CMicrolocks/LoveList, pour
pouvoir la scaler ou la gérer indépendamment si l'appli prend. **Chaque
appli a aussi sa propre base de données dédiée** (pas de DB partagée) : Gaia
a un chat, CMicrolocks tape en continu sur la DB (messages, RDV) — les deux
sont des profils "bruyants" qui justifient une isolation complète plutôt
qu'un partage à risque de ralentissement mutuel.

| Ressource | Offre | Prix |
|---|---|---|
| VPS Gaia (`gaia-vps/`) | DEV1-S (2 vCPU, 2 Go RAM) | €6.34/mois |
| VPS partagée CMicrolocks + LoveList (`shared-vps/`) | DEV1-M (3 vCPU, 4 Go RAM) | €14.26/mois |
| Managed Database for PostgreSQL — Gaia | DEV-S, dédiée | €11/mois |
| Managed Database for PostgreSQL — CMicrolocks | DEV-S, dédiée | €11/mois |
| Managed Database for PostgreSQL — LoveList | DEV-S, dédiée | €11/mois |
| **Total** | | **~€53.60/mois** |

⚠️ Dépasse volontairement le plafond initial de €50/mois de ~€3.60, choix
assumé pour l'isolation complète des 3 DB (voir mémoire `project_scaleway_hosting_separation`).

## 1. Créer les ressources Scaleway (console, à faire toi-même — facturation)

1. Compte Scaleway + projet dédié (ex: "hizope-prod").
2. **2 instances** (Ubuntu 24.04 LTS, zone Paris) :
   - `gaia-vps` — offre DEV1-S
   - `shared-vps` — offre DEV1-M
3. **3 instances Managed Database for PostgreSQL** séparées, offre **DEV-S**,
   zone Paris — une par appli : `db-gaia`, `db-cmicrolocks`, `db-lovelist`.
   Chacune avec sa propre base à l'intérieur (`GaiaDb`, `cmicrolocks`,
   `lovelist` respectivement).
4. DNS : crée les enregistrements
   - `api.gaia.tondomaine.fr` → IP publique de `gaia-vps`
   - `api.cmicrolocks.tondomaine.fr` → IP publique de `shared-vps`

## 2. Sur chaque VPS (SSH)

**Sur `gaia-vps`** :
```bash
curl -fsSL https://get.docker.com | sh
git clone https://github.com/Hizopee/Gaia-backend.git Gaia-backend
git clone <url-de-ce-dossier-deploy> hizope-scaleway-deploy
cd hizope-scaleway-deploy/gaia-vps
cp .env.example .env
nano .env          # vraies infos de l'instance Managed PostgreSQL "db-gaia"
nano Caddyfile     # remplacer TON-DOMAINE.fr par le vrai domaine
```

**Sur `shared-vps`** :
```bash
curl -fsSL https://get.docker.com | sh
git clone https://github.com/Hizopee/CMicrolocks-backend.git CMicrolocks-backend
git clone https://github.com/Hizopee/LoveList-backend.git LoveList-backend
git clone <url-de-ce-dossier-deploy> hizope-scaleway-deploy
cd hizope-scaleway-deploy/shared-vps
cp .env.example .env
nano .env          # vraies infos de "db-cmicrolocks" et "db-lovelist" + clés externes LoveList (TMDB, OMDB, IGDB, Google Books)
nano Caddyfile
```

Adapte les chemins `context:` des `docker-compose.prod.yml` si l'arborescence
sur les VPS ne reproduit pas celle de ton PC.

## 3. Appliquer les migrations EF Core contre chaque base managée (une fois, avant le premier démarrage)

Depuis ton poste (ou une des VPS), avec la vraie connection string de prod
de chaque instance dans les variables d'environnement / user-secrets :

```bash
dotnet tool run dotnet-ef database update --project Gaia.Infrastructure --startup-project GaiaWebApi
dotnet tool run dotnet-ef database update --project CMicrolocks.Infrastructure --startup-project CMicrolocks/CMicrolocks.API.csproj
dotnet tool run dotnet-ef database update   # depuis la racine de LoveList-backend
```

## 4. Lancer

Sur `gaia-vps` :
```bash
cd hizope-scaleway-deploy/gaia-vps
docker compose -f docker-compose.prod.yml up -d --build
```

Sur `shared-vps` :
```bash
cd hizope-scaleway-deploy/shared-vps
docker compose -f docker-compose.prod.yml up -d --build
```

Caddy obtient les certificats HTTPS automatiquement au premier lancement sur
chaque VPS (le DNS doit déjà pointer vers la bonne IP à ce moment-là).

## Test en local (avant tout déploiement)

Un seul Postgres local avec 3 bases (`GaiaDb`, `cmicrolocks`, `LoveListDb`)
suffit pour tester en local — la séparation en 3 instances dédiées est une
décision de prod (isolation des ressources), pas un besoin pour le dev
local. Voir `docker-compose.local.yml` + `init-databases.sql` à la racine
de ce dossier.

## État des migrations DB par appli

Les 3 migrations SQL Server → PostgreSQL sont faites, testées en conditions
réelles contre un vrai Postgres local (schéma créé, appli démarrée,
écritures confirmées en base), et committées — aucune n'est encore mergée.

- **Gaia** : branche `panthierjoyce/hiz-196-migrer-la-base-de-donnees-sql-server-vers-postgresql`
- **CMicrolocks** : branche `panthierjoyce/hiz-197-migrer-la-base-de-donnees-sql-server-vers-postgresql`
- **LoveList** : branche `panthierjoyce/hiz-198-migrer-la-base-de-donnees-sql-server-vers-postgresql`

Reste à faire avant la bascule prod, pour chaque appli : exécuter le script
pgloader (`pgloader-azure-to-scaleway.load` à la racine de chaque repo)
avec les vraies infos de connexion Azure SQL une fois les instances
Scaleway créées, puis comparer un échantillon de données migrées.
