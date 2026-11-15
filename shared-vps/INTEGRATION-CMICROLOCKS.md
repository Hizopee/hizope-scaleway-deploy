# Environnement d'intégration CMicrolocks

Espace de test pour Cécilia : on y valide un correctif ou une fonctionnalité **avant** de
la mettre en production, sans toucher aux vraies clientes.

| | Production | Intégration |
|---|---|---|
| Site de réservation | https://cmicrolocks.fr | https://int.cmicrolocks.fr |
| Admin | https://admin.cmicrolocks.fr | https://admin-int.cmicrolocks.fr |
| Branche Git | `main` | `integration` |
| Base de données | `Microlocks` | `Microlocks_Integration` (données de démo) |
| Paiements | Stripe live | simulés, ou Stripe **test** |
| SMS / e-mails / notifications | réels | **simulés** (écrits dans les journaux de l'API) |

L'API n'a pas de domaine propre : le site et l'admin la joignent sur leur propre domaine
(`/api`), comme en production.

## Circuit d'une modification

1. La PR est ouverte vers `integration` (et non `main`) dans le dépôt concerné
   (`CMicrolocks-backend`, `CMicrolocks-admin`, `CMicrolocks-client-web`).
2. Au merge, le déploiement part tout seul vers l'espace de test.
3. Cécilia teste sur `int.cmicrolocks.fr` / `admin-int.cmicrolocks.fr` et valide.
4. La même modification est ensuite mergée dans `main` (production). Seule Joyce merge.

`integration` doit rester **à jour de `main`** (après chaque merge sur `main`, remettre
`integration` au niveau de `main`), sinon on teste autre chose que ce qui partira en prod.

## Mise en place (une seule fois)

### 1. DNS chez OVH

Trois enregistrements `A` vers `62.210.78.72` (comme `cmicrolocks.fr`) :
`int`, `admin-int` pour la zone `cmicrolocks.fr`. (Pas de domaine d'API séparé.)

### 2. Base de données sur la VPS

Le script `postgres/init/01-create-databases.sh` ne s'exécute qu'à la **création** du volume :
la base doit donc être ajoutée à la main sur le Postgres existant.

```bash
cd ~/hizope-scaleway-deploy/shared-vps
PGPASS=$(openssl rand -hex 24); echo "$PGPASS"   # à noter pour le .env ci-dessous
docker compose -f docker-compose.prod.yml exec -T postgres psql -U postgres <<SQL
CREATE ROLE cmicrolocks_int LOGIN PASSWORD '$PGPASS';
CREATE DATABASE "Microlocks_Integration" OWNER cmicrolocks_int;
REVOKE ALL ON DATABASE "Microlocks_Integration" FROM PUBLIC;
SQL
```

### 3. Variables du `.env` de la VPS

Ajouter (voir `.env.example`) : `CMICROLOCKS_INT_DB_CONNECTION` (avec le mot de passe de
l'étape 2), `CMICROLOCKS_INT_JWT_KEY` (`openssl rand -base64 48`),
`CMICROLOCKS_INT_ADMIN_PASSWORD`. Les clés Stripe de **test** sont optionnelles : sans elles,
l'acompte est simulé.

### 4. Branches `integration`

Dans chaque dépôt, créer la branche `integration` à partir de `main`, une fois les workflows
`deploy-integration.yml` mergés dans `main`. Chaque dépôt déploie sur un push vers
`integration`.

### 5. Premier déploiement

Pousser `integration` (backend en premier) : l'API démarre, applique les migrations et
crée les données de démo. Puis admin et site.

## Données de démo

Avec `Seed__DemoData=true`, la base reçoit au premier démarrage les cliente/RDV fictifs du
jeu de test (`TestScenariosSeed`) : comptes `*.test@microlocks.local`, mot de passe
`Test1234!`. L'admin est `admin@microlocks.local` avec le mot de passe
`CMICROLOCKS_INT_ADMIN_PASSWORD`.

## Voir les SMS et e-mails simulés

Rien ne part vers de vraies personnes. Pour lire un SMS (lien de confirmation, proposition de
la liste d'attente…) :

```bash
cd ~/hizope-scaleway-deploy/shared-vps
docker compose -f docker-compose.prod.yml logs --tail 100 cmicrolocks-int-api | grep -i sms
```

## Fuseau horaire

Le conteneur est réglé sur `America/Guadeloupe` (variable `TZ`). Les rendez-vous sont saisis à
l'heure du salon ; les tâches de fond (demande de confirmation à J-3, expiration, rappels) les
comparent à l'heure « maintenant » du serveur, qui doit donc être l'heure du salon.
