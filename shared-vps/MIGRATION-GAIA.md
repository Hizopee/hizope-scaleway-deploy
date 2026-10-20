# Déménagement de Gaia sur la VPS partagée

Objectif : supprimer `gaia-vps` (DEV1-S + son IPv4 + son disque) et `db-gaia` (base managée)
en faisant tourner Gaia sur `shared-vps`, avec sa base dans le PostgreSQL de la VPS.
Économie : ≈ 11 € HT/mois (serveur) + ≈ 25 € HT/mois (base managée).

Au passage : les photos de profil et enregistrements vocaux de Gaia (`/app/Assets`) sont
désormais sur un volume persistant. Sur `gaia-vps`, ils étaient effacés à chaque déploiement.

Coupure de Gaia : quelques minutes (étapes 5 à 9), à condition d'avoir baissé le TTL DNS
(étape 1) au moins une heure avant.

---

## 1. La veille ou au moins 1 h avant : baisser le TTL DNS (OVH)

OVH → Domaines → `gaia-app.fr` → Zone DNS. Pour les 3 enregistrements **A** (`@`, `www`,
`api`, cible `62.210.87.185`) : `⋮` → *Modifier* → TTL **60** secondes.
Les navigateurs oublieront ainsi l'ancienne adresse en 1 minute au moment de la bascule.

## 2. Préparer le `.env` de la VPS partagée

Sur `gaia-vps` (`ssh root@62.210.87.185`), afficher les deux valeurs à recopier :

```
grep '^GAIA_' ~/hizope-scaleway-deploy/gaia-vps/.env
```

Sur `shared-vps` (`ssh root@62.210.78.72`) :

```
cd ~/hizope-scaleway-deploy && git pull && cd shared-vps
nano .env
```

Coller à la fin les deux lignes `GAIA_DB_CONNECTION=…` et `GAIA_JWT_KEY=…` copiées depuis
gaia-vps, enregistrer, puis :

```
grep -q '^GAIA_PG_PASSWORD=' .env || echo "GAIA_PG_PASSWORD=$(openssl rand -hex 24)" >> .env
docker compose -f docker-compose.prod.yml up -d db-backup
```

## 3. Premier déploiement de Gaia sur la VPS partagée (Claude)

Merge de la PR « ci: image Gaia construite sur GitHub, déployée sur shared-vps » du dépôt
Gaia-backend : GitHub construit l'image et démarre `gaia-api` sur la VPS partagée, encore
branché sur la base managée. Le site public reste servi par gaia-vps (le DNS n'a pas bougé).

## 4. Vérifier que Gaia démarre sur la VPS partagée

```
docker compose -f docker-compose.prod.yml ps gaia-api
docker compose -f docker-compose.prod.yml logs --tail 20 gaia-api
```

Statut `Up`, et « Application started » dans le journal.

## 5. Arrêter Gaia sur gaia-vps (début de la coupure)

Sur `gaia-vps` :

```
cd ~/hizope-scaleway-deploy/gaia-vps
docker compose -f docker-compose.prod.yml stop gaia-api
docker cp gaia-vps-gaia-api-1:/app/Assets /root/gaia-assets
ls -R /root/gaia-assets | head
```

## 6. Copier les photos et enregistrements vers la VPS partagée

Depuis **ton PC** (Git Bash), en une commande (le PC sert de relais entre les deux serveurs) :

```
ssh root@62.210.87.185 "tar -C /root/gaia-assets -czf - ." | ssh root@62.210.78.72 "mkdir -p /root/gaia-assets && tar -C /root/gaia-assets -xzf -"
```

Puis sur `shared-vps` :

```
cd ~/hizope-scaleway-deploy/shared-vps
docker compose -f docker-compose.prod.yml cp /root/gaia-assets/. gaia-api:/app/Assets/
```

## 7. Migrer la base

```
./scripts/migrate-db.sh gaia
```

Même déroulé que pour les autres applis : `o`, toutes les tables `OK`, bascule du `.env`.

## 8. Basculer le DNS (OVH)

Zone DNS de `gaia-app.fr` : modifier les 3 enregistrements **A** (`@`, `www`, `api`) →
cible **`62.210.78.72`**. Vérifier depuis la VPS partagée :

```
getent hosts api.gaia-app.fr gaia-app.fr www.gaia-app.fr
```

Les trois doivent afficher `62.210.78.72` (attendre une minute si ce n'est pas le cas).

## 9. Activer Gaia dans Caddy (certificats HTTPS)

```
docker compose -f docker-compose.prod.yml up -d caddy
docker compose -f docker-compose.prod.yml logs --tail 30 caddy | grep -i gaia
```

Caddy redémarre (2-3 secondes pour tous les sites) et obtient les certificats de
`gaia-app.fr`, `www.gaia-app.fr` et `api.gaia-app.fr`. Vérifier https://gaia-app.fr et
l'application mobile Gaia : **fin de la coupure**.

Remettre ensuite le TTL des 3 enregistrements à sa valeur par défaut (OVH).

## 10. Après 7 jours sans incident

Console Scaleway :
- Instances → supprimer `gaia-vps` **et son IP flexible** (`62.210.87.185`) ;
- Managed Databases → supprimer `db-gaia`.

---

## Retour arrière

Avant l'étape 10 : remettre les 3 enregistrements DNS sur `62.210.87.185`, puis sur gaia-vps
`docker compose -f docker-compose.prod.yml start gaia-api`. Les données écrites entre-temps
sur la VPS partagée ne sont pas recopiées vers la base managée.
