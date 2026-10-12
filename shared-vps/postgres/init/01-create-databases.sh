#!/bin/sh
# Exécuté UNE SEULE FOIS par l'image postgres, au tout premier démarrage (volume
# postgres_data vide). Crée une base + un utilisateur dédié par application : une appli
# compromise ne peut pas lire les données des autres.
#
# Les mots de passe viennent du .env (générés avec `openssl rand -hex 24` : uniquement
# des caractères hexadécimaux, donc pas d'échappement SQL nécessaire).
set -eu

create_app_database() {
  role="$1"
  password="$2"
  database="$3"

  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
CREATE ROLE "$role" LOGIN PASSWORD '$password';
CREATE DATABASE "$database" OWNER "$role";
REVOKE ALL ON DATABASE "$database" FROM PUBLIC;
SQL
}

# Noms de bases identiques à ceux des bases managées (casse comprise) : seules les
# chaînes de connexion changent côté applications.
create_app_database cmicrolocks "$CMICROLOCKS_PG_PASSWORD" Microlocks
create_app_database lovelist "$LOVELIST_PG_PASSWORD" LoveListDb
create_app_database lovelist_int "$LOVELIST_INT_PG_PASSWORD" LoveListDb_Integration
