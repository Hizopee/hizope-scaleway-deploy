#!/usr/bin/env bash
# Migre UNE application de sa base PostgreSQL managée Scaleway vers le PostgreSQL de la VPS.
#
#   cd ~/hizope-scaleway-deploy/shared-vps
#   ./scripts/migrate-db.sh lovelist-int     # puis lovelist, puis cmicrolocks
#
# Déroulé : vérifications -> arrêt de l'API -> pg_dump de la base managée -> pg_restore dans
# le conteneur postgres -> comparaison du nombre de lignes table par table -> mise à jour de
# la chaîne de connexion dans .env (copie de sauvegarde .env.bak-...) -> redémarrage de l'API.
# En cas d'échec AVANT la mise à jour du .env, l'API est relancée sur la base managée : rien
# n'est perdu. La base managée n'est jamais modifiée (lecture seule).
set -Eeuo pipefail

cd "$(dirname "$0")/.."
COMPOSE=(docker compose -f docker-compose.prod.yml)

case "${1:-}" in
  cmicrolocks)
    SERVICE=cmicrolocks-api; ENV_VAR=CMICROLOCKS_DB_CONNECTION
    DB=Microlocks; ROLE=cmicrolocks; PASS_VAR=CMICROLOCKS_PG_PASSWORD ;;
  lovelist)
    SERVICE=lovelist-api; ENV_VAR=LOVELIST_DB_CONNECTION
    DB=LoveListDb; ROLE=lovelist; PASS_VAR=LOVELIST_PG_PASSWORD ;;
  lovelist-int)
    SERVICE=lovelist-int-api; ENV_VAR=LOVELIST_INT_DB_CONNECTION
    DB=LoveListDb_Integration; ROLE=lovelist_int; PASS_VAR=LOVELIST_INT_PG_PASSWORD ;;
  gaia)
    SERVICE=gaia-api; ENV_VAR=GAIA_DB_CONNECTION
    DB=GaiaDb; ROLE=gaia; PASS_VAR=GAIA_PG_PASSWORD ;;
  *)
    echo "Usage : $0 <cmicrolocks|lovelist|lovelist-int|gaia>" >&2
    exit 1 ;;
esac

# Jamais de `source .env` : certaines valeurs contiennent des espaces non échappés.
env_value() { grep "^$1=" .env | head -n 1 | cut -d'=' -f2- || true; }

# Lit une clé d'une chaîne de connexion Npgsql ("Host=...;Port=...;...").
conn_part() {
  local conn="$1"; shift
  local key
  for key in "$@"; do
    local value
    value=$(printf '%s' "$conn" | tr ';' '\n' \
      | awk -v k="$key" '{ split($0, kv, "="); name = kv[1]; gsub(/^ +| +$/, "", name)
          if (tolower(name) == tolower(k)) { sub(/^[^=]*=/, ""); print; exit } }')
    if [ -n "$value" ]; then printf '%s' "$value"; return; fi
  done
}

psql_target() { "${COMPOSE[@]}" exec -T postgres psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -tA "$@"; }
psql_source() {
  "${COMPOSE[@]}" exec -T -e PGPASSWORD="$SRC_PASS" -e PGSSLMODE=require postgres \
    psql -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" -v ON_ERROR_STOP=1 -tA "$@"
}

SOURCE_CONN=$(env_value "$ENV_VAR")
TARGET_PASS=$(env_value "$PASS_VAR")

if [ -z "$SOURCE_CONN" ]; then
  echo "❌ $ENV_VAR introuvable dans .env" >&2; exit 1
fi
if [ "$(conn_part "$SOURCE_CONN" Host Server)" = "postgres" ]; then
  echo "✅ $ENV_VAR pointe déjà sur le PostgreSQL de la VPS : rien à faire."; exit 0
fi
if [ -z "$TARGET_PASS" ]; then
  echo "❌ $PASS_VAR manquant dans .env (voir MIGRATION-POSTGRES.md, étape 3)" >&2; exit 1
fi

SRC_HOST=$(conn_part "$SOURCE_CONN" Host Server)
SRC_PORT=$(conn_part "$SOURCE_CONN" Port); SRC_PORT=${SRC_PORT:-5432}
SRC_DB=$(conn_part "$SOURCE_CONN" Database)
SRC_USER=$(conn_part "$SOURCE_CONN" Username "User Id" "User ID" User)
SRC_PASS=$(conn_part "$SOURCE_CONN" Password)

echo "== Migration $1"
echo "   source : $SRC_USER@$SRC_HOST:$SRC_PORT/$SRC_DB (base managée, lecture seule)"
echo "   cible  : $ROLE@postgres:5432/$DB (VPS)"

echo "-- Vérifications"
"${COMPOSE[@]}" exec -T postgres pg_isready -U postgres >/dev/null \
  || { echo "❌ Le conteneur postgres ne répond pas (docker compose up -d postgres)" >&2; exit 1; }

# Base et utilisateur créés à la volée s'ils n'existent pas encore (appli ajoutée après le
# premier démarrage de postgres, ex. Gaia : postgres/init/ ne s'exécute qu'une fois).
psql_admin() { "${COMPOSE[@]}" exec -T postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -tA "$@"; }
if [ "$(psql_admin -c "select 1 from pg_roles where rolname = '$ROLE'")" != "1" ]; then
  psql_admin -c "CREATE ROLE \"$ROLE\" LOGIN PASSWORD '$TARGET_PASS'" >/dev/null
  echo "   utilisateur $ROLE créé"
fi
if [ "$(psql_admin -c "select 1 from pg_database where datname = '$DB'")" != "1" ]; then
  psql_admin -c "CREATE DATABASE \"$DB\" OWNER \"$ROLE\"" >/dev/null
  psql_admin -c "REVOKE ALL ON DATABASE \"$DB\" FROM PUBLIC" >/dev/null
  echo "   base $DB créée"
fi
psql_source -c "select 1" >/dev/null \
  || { echo "❌ Connexion à la base managée impossible" >&2; exit 1; }
existing=$(psql_target -c "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")
if [ "$existing" != "0" ]; then
  echo "❌ La base cible $DB contient déjà $existing table(s). Migration déjà faite ou à nettoyer :" >&2
  echo "   docker compose -f docker-compose.prod.yml exec postgres psql -U postgres -c 'DROP DATABASE \"$DB\"; CREATE DATABASE \"$DB\" OWNER $ROLE;'" >&2
  exit 1
fi
echo "   OK"

read -r -p "Arrêter $SERVICE (coupure de quelques minutes) et migrer ? [o/N] " answer
[ "$answer" = "o" ] || [ "$answer" = "O" ] || { echo "Annulé."; exit 0; }

restart_on_old_database() {
  echo "❌ Échec : $SERVICE est relancé sur la base managée (rien n'a changé dans .env)." >&2
  "${COMPOSE[@]}" start "$SERVICE" || true
}
trap restart_on_old_database ERR

echo "-- Arrêt de $SERVICE"
"${COMPOSE[@]}" stop "$SERVICE"

DUMP="/backups/migration-$DB-$(date -u +%Y%m%d-%H%M%S).dump"
echo "-- Export de la base managée"
"${COMPOSE[@]}" exec -T -e PGPASSWORD="$SRC_PASS" -e PGSSLMODE=require postgres \
  pg_dump -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" -Fc --no-owner --no-privileges -f "$DUMP"

echo "-- Import dans le PostgreSQL de la VPS"
"${COMPOSE[@]}" exec -T postgres \
  pg_restore -U postgres -d "$DB" --no-owner --no-privileges --role="$ROLE" --exit-on-error "$DUMP"

echo "-- Comparaison du nombre de lignes"
mismatch=0
tables=$(psql_target -c "select quote_ident(schemaname) || '.' || quote_ident(tablename) from pg_tables
                         where schemaname not in ('pg_catalog','information_schema') order by 1")
for table in $tables; do
  src=$(psql_source -c "select count(*) from $table")
  dst=$(psql_target -c "select count(*) from $table")
  if [ "$src" = "$dst" ]; then
    printf '   %-45s %8s  OK\n' "$table" "$dst"
  else
    printf '   %-45s %8s -> %s  DIFFÉRENT\n' "$table" "$src" "$dst"
    mismatch=1
  fi
done
if [ "$mismatch" -ne 0 ]; then
  echo "Des tables diffèrent." >&2
  false
fi

echo "-- Bascule de $ENV_VAR dans .env"
BACKUP_ENV=".env.bak-$(date +%Y%m%d-%H%M%S)"
cp -p .env "$BACKUP_ENV"
NEW_CONN="Host=postgres;Port=5432;Database=$DB;Username=$ROLE;Password=$TARGET_PASS"
awk -v k="$ENV_VAR" -v v="$NEW_CONN" 'index($0, k "=") == 1 { print k "=" v; next } { print }' .env > .env.tmp
cat .env.tmp > .env && rm .env.tmp
trap - ERR

echo "-- Redémarrage de $SERVICE sur le PostgreSQL de la VPS"
"${COMPOSE[@]}" up -d "$SERVICE"
sleep 20
"${COMPOSE[@]}" ps "$SERVICE"
"${COMPOSE[@]}" logs --tail 20 "$SERVICE"

cat <<EOF

✅ Migration de $1 terminée. Vérifie l'application dans le navigateur.
   Ancienne configuration gardée dans $BACKUP_ENV.

   Retour arrière (perd les données écrites depuis la bascule) :
     cp $BACKUP_ENV .env && docker compose -f docker-compose.prod.yml up -d $SERVICE
EOF
