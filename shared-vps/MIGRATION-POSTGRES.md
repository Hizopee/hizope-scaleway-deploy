# Migration des bases managées vers PostgreSQL sur la VPS partagée

Objectif : supprimer `db-cmicrolocks` et `db-lovelist` (Managed Database DEV-S, 2 nœuds
chacune) au profit d'un conteneur PostgreSQL sur `shared-vps`, avec une sauvegarde
quotidienne vers Scaleway Object Storage. Économie : ≈ 50 € HT/mois pour ces deux bases.

`db-gaia` reste managée tant que Gaia tourne sur `gaia-vps` : elle sera migrée au moment où
Gaia rejoindra la VPS partagée (le PostgreSQL de la VPS n'est pas exposé sur Internet).

Les bases managées ne sont **jamais modifiées** par cette procédure (lecture seule) : tant
qu'elles ne sont pas supprimées (étape 8), le retour arrière reste possible.

---

## 1. Console Scaleway (avant tout)

1. **Agrandir le disque de la VPS** : Instances → `shared-vps` → Volumes → volume système →
   *Augmenter la taille* → **40 Go**. Le disque fait 10 Go et est déjà presque plein
   (déploiements en échec « No space left on device » le 12/10).
2. **Créer le bucket de sauvegarde** : Object Storage → *Créer un bucket* → nom
   `mhq-db-backups` (si le nom est pris, en choisir un autre et le reporter dans
   `BACKUP_S3_BUCKET`), région **Paris**, visibilité **privée**.
3. **Créer la clé d'accès au bucket** : IAM → Applications → *Créer* `mhq-db-backup` →
   Policy avec le permission set **ObjectStorageFullAccess**, limitée au projet **MHQ** →
   sur l'application, *Générer une clé API*. Noter l'**Access Key** (`SCW...`) et la
   **Secret Key** (affichée une seule fois).

## 2. Sur la VPS : agrandir la partition et récupérer la configuration

```bash
ssh root@62.210.78.72
lsblk            # repérer le disque système et sa partition (ex. sda / sda1)
df -h /          # taille actuelle
```

Si `lsblk` montre un disque de 40 Go mais une partition plus petite (adapter les noms) :

```bash
growpart /dev/sda 1
resize2fs /dev/sda1
df -h /          # doit maintenant afficher ~40 Go
```

Puis :

```bash
cd ~/hizope-scaleway-deploy && git pull
cd shared-vps
```

## 3. Compléter le `.env`

Mots de passe PostgreSQL (générés aléatoirement, ajoutés seulement s'ils n'existent pas) :

```bash
for v in POSTGRES_PASSWORD CMICROLOCKS_PG_PASSWORD LOVELIST_PG_PASSWORD LOVELIST_INT_PG_PASSWORD; do
  grep -q "^$v=" .env || echo "$v=$(openssl rand -hex 24)" >> .env
done
```

Puis `nano .env` et ajouter à la fin :

```
BACKUP_S3_BUCKET=mhq-db-backups
BACKUP_S3_ACCESS_KEY=<Access Key de l'étape 1.3>
BACKUP_S3_SECRET_KEY=<Secret Key de l'étape 1.3>
```

⚠️ Ne plus jamais modifier les quatre mots de passe PostgreSQL : ils ne sont lus qu'à la
création des bases (premier démarrage du conteneur).

## 4. Démarrer PostgreSQL et les sauvegardes

```bash
docker compose -f docker-compose.prod.yml up -d postgres db-backup
docker compose -f docker-compose.prod.yml exec postgres psql -U postgres -c '\l'
```

La liste doit contenir `Microlocks`, `LoveListDb` et `LoveListDb_Integration`.

Tester la sauvegarde tout de suite (bases encore vides, c'est normal) :

```bash
docker compose -f docker-compose.prod.yml exec db-backup /backup.sh --now
```

Trois lignes « sauvegarde OK » doivent s'afficher, et les fichiers apparaître dans le bucket.

## 5. Merger les PR LoveList (avant de migrer LoveList)

Les déploiements LoveList appliquent les migrations EF dans un conteneur jetable : les PR
« migrations EF sur le réseau shared-vps_default » (branches `main` et `integration` de
LoveList-backend) le branchent sur le réseau de la VPS pour qu'il joigne `postgres`.

## 6. Migrer, une application à la fois

Le script arrête l'API, copie la base, compare le nombre de lignes de chaque table, met à
jour la chaîne de connexion dans `.env` (copie `.env.bak-...` gardée) et relance l'API.
S'il échoue avant la mise à jour du `.env`, l'API repart sur la base managée.

Dans cet ordre, du moins risqué au plus sensible :

```bash
./scripts/migrate-db.sh lovelist-int    # puis vérifier https://int.lovelist.shop
./scripts/migrate-db.sh lovelist        # puis vérifier https://lovelist.shop
./scripts/migrate-db.sh cmicrolocks     # de préférence le soir ; vérifier admin + site client
```

Coupure : quelques minutes par application.

## 7. Tester une restauration

```bash
docker compose -f docker-compose.prod.yml exec db-backup /backup.sh --now
docker compose -f docker-compose.prod.yml exec postgres sh -c '
  f=$(ls -t /backups/Microlocks-*.dump | head -n 1) &&
  createdb -U postgres restore_test &&
  pg_restore -U postgres -d restore_test --no-owner "$f" &&
  psql -U postgres -d restore_test -c "select count(*) as rdv from \"Appointments\"" ;
  dropdb -U postgres restore_test'
```

Le nombre de rendez-vous affiché doit correspondre à celui de l'application.

## 8. Supprimer les bases managées (après 7 jours sans incident)

Console → Managed Databases → supprimer `db-cmicrolocks` et `db-lovelist` (leurs snapshots
partent avec). Ne pas toucher à `db-gaia`.

---

## Retour arrière

Tant que l'étape 8 n'est pas faite, pour une application :

```bash
cp .env.bak-AAAAMMJJ-HHMMSS .env      # le fichier indiqué à la fin du script
docker compose -f docker-compose.prod.yml up -d <cmicrolocks-api|lovelist-api|lovelist-int-api>
```

Les données écrites depuis la bascule ne sont pas recopiées vers la base managée.

## Au quotidien

- Sauvegardes : chaque nuit à 02:00 UTC, 14 jours gardés dans le bucket, 3 jours en local.
  Journal : `docker compose -f docker-compose.prod.yml logs db-backup`.
- Mise à jour mineure de PostgreSQL (17.x) : `docker compose -f docker-compose.prod.yml pull postgres && docker compose -f docker-compose.prod.yml up -d postgres`.
