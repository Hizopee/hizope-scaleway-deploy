#!/bin/sh
# Sauvegarde quotidienne des bases PostgreSQL de la VPS partagée vers Scaleway Object
# Storage (remplace les sauvegardes automatiques des bases managées).
#
# - Tous les jours à BACKUP_HOUR (UTC) : pg_dump (format custom, compressé) de chaque base
#   de BACKUP_DATABASES, envoyé dans s3://$BACKUP_S3_BUCKET/<base>/<base>-AAAA-MM-JJ.dump
# - Copies locales (volume db_backups) gardées 3 jours, copies distantes BACKUP_RETENTION_DAYS.
# - `docker compose exec db-backup /backup.sh --now` : sauvegarde immédiate (test, ou avant
#   une opération risquée).
set -eu

S3_ENDPOINT="https://s3.fr-par.scw.cloud"
export AWS_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_KEY"
export AWS_DEFAULT_REGION="fr-par"
export PGPASSWORD="$POSTGRES_PASSWORD"

if ! command -v aws >/dev/null 2>&1; then
  apk add --no-cache aws-cli >/dev/null
fi

s3() {
  aws --endpoint-url "$S3_ENDPOINT" s3 "$@"
}

run_backup() {
  stamp=$(date -u +%Y-%m-%d)
  status=0

  for db in $BACKUP_DATABASES; do
    file="/backups/$db-$stamp.dump"
    if pg_dump -h postgres -U postgres -Fc -d "$db" -f "$file" \
      && s3 cp "$file" "s3://$BACKUP_S3_BUCKET/$db/$db-$stamp.dump" --only-show-errors; then
      echo "$(date -u +%FT%TZ) sauvegarde OK : $db ($(du -h "$file" | cut -f1))"
    else
      echo "$(date -u +%FT%TZ) ERREUR de sauvegarde : $db" >&2
      status=1
    fi
  done

  find /backups -name '*.dump' -mtime +2 -delete

  # Rétention distante : supprime les fichiers plus vieux que BACKUP_RETENTION_DAYS.
  cutoff=$(date -u -d "@$(( $(date +%s) - BACKUP_RETENTION_DAYS * 86400 ))" +%Y%m%d)
  for db in $BACKUP_DATABASES; do
    s3 ls "s3://$BACKUP_S3_BUCKET/$db/" 2>/dev/null | awk '{print $4}' | while read -r name; do
      day=$(echo "$name" | sed -n 's/.*-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)\.dump$/\1/p' | tr -d -)
      if [ -n "$day" ] && [ "$day" -lt "$cutoff" ]; then
        s3 rm "s3://$BACKUP_S3_BUCKET/$db/$name" --only-show-errors
      fi
    done
  done

  return $status
}

if [ "${1:-}" = "--now" ]; then
  run_backup
  exit $?
fi

echo "Sauvegardes planifiées chaque jour à ${BACKUP_HOUR}:00 UTC : $BACKUP_DATABASES"
while true; do
  now=$(date -u +%s)
  next=$(date -u -d "$(date -u +%Y-%m-%d) ${BACKUP_HOUR}:00:00" +%s)
  if [ "$next" -le "$now" ]; then
    next=$(( next + 86400 ))
  fi
  sleep $(( next - now ))
  run_backup || true
done
