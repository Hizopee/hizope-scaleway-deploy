# Déploiement Scaleway — Gaia + CMicrolocks (+ LoveList) — ~€109.50/mois (réel)

Gaia est hébergée sur sa propre VPS, séparée de CMicrolocks/LoveList, pour
pouvoir la scaler ou la gérer indépendamment si l'appli prend. **Chaque
appli a aussi sa propre base de données dédiée** (pas de DB partagée) : Gaia
a un chat, CMicrolocks tape en continu sur la DB (messages, RDV) — les deux
sont des profils "bruyants" qui justifient une isolation complète plutôt
qu'un partage à risque de ralentissement mutuel.

| Ressource | Offre | Prix catalogue | Prix réel |
|---|---|---|---|
| VPS Gaia (`gaia-vps/`) ✅ créée | DEV1-S (2 vCPU, 2 Go RAM) | €6.34/mois | **€11.15/mois** |
| VPS partagée CMicrolocks + LoveList (`shared-vps/`) ✅ créée | DEV1-M (3 vCPU, 4 Go RAM) | €14.26/mois | **€19.35/mois** |
| Managed Database for PostgreSQL — `db-gaia` ✅ créée | DEV-S, dédiée, HA 2 nodes | €11/mois | **€23.30/mois** |
| Managed Database for PostgreSQL — `db-cmicrolocks` ✅ créée | DEV-S, dédiée, HA 2 nodes | €11/mois | **€23.30/mois** |
| Managed Database for PostgreSQL — `db-lovelist` ✅ créée | DEV-S, dédiée, HA 2 nodes | €11/mois | **€23.30/mois** |
| **Total** | | ~€53.60/mois | **~€100.40/mois** |

⚠️ Deux surprises de prix par rapport à l'estimation initiale, validées ensemble le 29/08 (choix : continuer quand même, isolation complète prioritaire sur le coût) :
- VPS : le prix catalogue n'inclut ni l'IP publique (€0.005/h ≈ €3.65/mois) ni le stockage bloc (10 Go ≈ €0.95-1.30/mois).
- Managed Database DEV-S : toujours livrée en **2 nodes (HA)**, pas d'option 1 node moins cher sur cette offre — €21.32/mois de config + €1.99/mois de stockage 10 Go = €23.30/mois réel, plus du double des €11/mois estimés au départ.

Dépasse le plafond initial de €50/mois de ~€59.50 — à surveiller si le coût
DB devient un problème (option de repli : Postgres auto-hébergé sur les VPS
au lieu de Managed Database, économiserait ~€70/mois sur les 3 DB). Voir
mémoire `project_scaleway_hosting_separation`.

## 1. Créer les ressources Scaleway (console, à faire toi-même — facturation)

1. Compte Scaleway + projet dédié ("MHQ").
2. ✅ **2 instances créées** (Ubuntu 26.04, zone Paris/PAR 1) :
   - `gaia-vps` — DEV1-S, IP publique `62.210.87.185`
   - `shared-vps` — DEV1-M, IP publique `62.210.78.72`
3. ✅ **3 instances Managed Database for PostgreSQL créées** (29/08), offre
   **DEV-S**, PostgreSQL 17, zone Paris : `db-gaia`, `db-cmicrolocks`,
   `db-lovelist`. Identifiants générés à la création, notés temporairement
   en local (pas committés), reportés dans les `.env` de chaque VPS. Chacune
   a sa base applicative créée à l'intérieur (`GaiaDb`, `Microlocks`,
   `LoveListDb` respectivement — attention à la casse exacte, cf.
   `.env.example`) et un **endpoint public + Allowed IPs** restreint aux IP
   des VPS + IP de poste local (pour les migrations `dotnet-ef` depuis le PC).
4. ✅ DNS fait (29/08) pour les 2 domaines :
   - `gaia-app.fr` (acheté 27/08) → `gaia-vps` (`62.210.87.185`) : `@`, `www`, `api`.
   - `cmicrlocks.fr` (acheté 29/08) → `shared-vps` (`62.210.78.72`) : `@`, `www`, `api`.

   Dans les deux cas, les anciens enregistrements de parking OVH par défaut
   (`213.186.33.5`) ont été supprimés/remplacés. Propagation DNS annoncée
   jusqu'à 24h par OVH mais observée quasi-instantanée dans les deux cas.

   LoveList n'a pas de domaine dédié pour l'instant (pas dans le périmètre
   du 29/08) — reste accessible en interne sur le réseau Docker de
   `shared-vps` (`lovelist-api:8080`), pas de route Caddy publique encore.

✅ **Les 3 applis sont déployées et fonctionnelles (29/08)** :
- Gaia : https://gaia-app.fr (site) + https://api.gaia-app.fr (API), `db-gaia` migrée + seedée automatiquement au démarrage.
- CMicrolocks : https://api.cmicrlocks.fr (API, testée avec vraies données `/api/salon-settings`), `db-cmicrolocks` (`Microlocks`) migrée + seedée automatiquement. Interface admin (Vue 3, repo `Hizopee/CMicrolocks-admin`) déployée en statique sur https://admin.cmicrlocks.fr — build `npm run build` copié à la main dans `shared-vps/admin-website/` sur le VPS (pas de pipeline CI/CD pour ce repo pour l'instant), Caddy proxie `/api/*` vers `cmicrolocks-api` sur ce même domaine pour que les appels relatifs du front fonctionnent sans changement de code. Beaucoup d'écrans de cette interface utilisent encore des données mockées (`src/mocks/`) plutôt que les vrais endpoints — à vérifier écran par écran avant de la considérer prête pour un usage réel.
- LoveList : API fonctionnelle en interne (`lovelist-api:8080`), `db-lovelist` (`LoveListDb`) — migrations appliquées manuellement (`dotnet ef database update`, pas d'auto-migrate dans le code).

Plusieurs bugs de déploiement trouvés et corrigés en route, PR mergées sur `main` :
- **Gaia-backend** : Dockerfile référençait le mauvais nom de csproj/dll après un renommage (`GaiaWebApi` → `Gaia.Api`), restore incomplet pour les `ProjectReference`, et un `UseUrls("http://0.0.0.0:5000")` en dur qui écrasait la config Docker même en Production. Bonus : le seeding tournait avant les migrations EF Core.
- **CMicrolocks-backend** : aucun Dockerfile n'existait dans le repo, créé en s'inspirant des mêmes leçons (restore après `COPY . .` à cause des `ProjectReference`).

✅ **Pipelines CI/CD en place et vérifiés (29/08)** pour les 3 apps — `.github/workflows/deploy.yml`
dans chaque repo, déclenché sur push vers `main` : SSH vers le VPS cible, `git pull`, rebuild et
redémarrage du conteneur via `docker compose`. Secret `DEPLOY_SSH_KEY` (une seule paire de clés,
autorisée sur les deux VPS) à ajouter dans les "Actions secrets" de chaque repo GitHub. Bugs trouvés
en testant les premiers runs réels : `git fetch` a besoin de `GIT_SSH_COMMAND` pointant vers la
deploy key du repo (pas de clé SSH git par défaut sur les VPS) ; `git checkout main` doit être forcé
(`checkout -f -B main origin/main`) pour ignorer d'éventuelles modifs locales faites en direct sur le
VPS ; le `.env` de `shared-vps` contient des espaces non échappés dans les valeurs
(`Ssl Mode=Require`), donc extraire une valeur précise se fait par `grep '^KEY=' .env | cut -d'=' -f2-`,
jamais par `source`. LoveList applique ses migrations EF Core manuellement à chaque déploiement
(`dotnet ef database update` dans un conteneur SDK jetable) car son code n'a pas d'auto-migrate au
démarrage, contrairement à Gaia et CMicrolocks.

## 2. Sur chaque VPS (SSH)

**Sur `gaia-vps`** :
```bash
curl -fsSL https://get.docker.com | sh
git clone https://github.com/Hizopee/Gaia-backend.git Gaia-backend
git clone <url-de-ce-dossier-deploy> hizope-scaleway-deploy
cd hizope-scaleway-deploy/gaia-vps
cp .env.example .env
nano .env          # vraies infos de l'instance Managed PostgreSQL "db-gaia"
```

Le domaine `gaia-app.fr` (acheté chez OVH le 27/08) est déjà en dur dans `gaia-vps/Caddyfile`, rien à changer — le Caddyfile sert aussi `gaia-vps/website/` en statique sur le domaine racine (la page d'accueil publique, nécessaire pour la validation Play Console du compte développeur Organisation).

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
