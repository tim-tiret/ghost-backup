BACKUP_DIR="/root/ghost/sauv"
DATA_FOLDER="/root/ghost"
DB_PASSWORD="ce-mot-de-passe-est-dingue"
GHOST_VOLUME="my_ghost_content"
DB_VOLUME="my_ghost_db"
SITE_URL="https://example.com"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

cd "$DATA_FOLDER" || {
    log_message "ERREUR: Impossible de se déplacer dans $DATA_FOLDER."
    exit 1
}

GHOST_BACKUP=$(ls -t "$BACKUP_DIR/ghost_content_"*.tar.gz 2>/dev/null | head -n1)
DB_BACKUP=$(ls -t "$BACKUP_DIR/ghost_db_"*.sql 2>/dev/null | head -n1)

if [ -z "$GHOST_BACKUP" ] || [ -z "$DB_BACKUP" ]; then
    log_message "ERREUR: Impossible de trouver les backups ghost_content_*.tar.gz ou ghost_db_*.sql."
    log_message "Vérifiez que vous avez bien des fichiers ghost_content_*.tar.gz et ghost_db_*.sql dans $BACKUP_DIR."
    exit 1
fi

log_message "Sauvegardes trouvées :"
log_message "- Ghost  : $(basename "$GHOST_BACKUP")"
log_message "- MySQL  : $(basename "$DB_BACKUP")"

CONFIG_BACKUP=$(ls -t "$BACKUP_DIR/config.production_"*.json 2>/dev/null | head -n1)
if [ -n "$CONFIG_BACKUP" ]; then
    log_message "- config.production.json : $(basename "$CONFIG_BACKUP")"
fi

read -p "Voulez-vous restaurer ces sauvegardes ? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_message "Restauration annulée."
    exit 0
fi

log_message "Arrêt des conteneurs..."
docker compose down

log_message "Restauration du volume '$GHOST_VOLUME'..."
docker volume rm $GHOST_VOLUME || true
docker volume create $GHOST_VOLUME
docker run --rm \
    -v $GHOST_VOLUME:/var/lib/ghost \
    -v "$BACKUP_DIR:/backup" \
    ubuntu bash -c "cd /var/lib/ghost && tar xzf /backup/$(basename "$GHOST_BACKUP") && mv content/* . && rmdir content"

log_message "Restauration de la base de données MySQL..."
docker volume rm $DB_VOLUME || true
docker volume create $DB_VOLUME

docker compose up -d db
sleep 10

docker compose exec -T db mysql -u root -p"$DB_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS ghost;"
docker compose exec -T db mysql -u root -p"$DB_PASSWORD" ghost < "$DB_BACKUP"

if [ -n "$CONFIG_BACKUP" ]; then
    log_message "Restauration de config.production.json..."
    cp "$CONFIG_BACKUP" "$DATA_FOLDER/config.production.json"
fi

log_message "Redémarrage des conteneurs..."
docker compose up -d

log_message "Attente du démarrage complet de Ghost..."
for i in {1..12}; do
    if curl -s -f "${SITE_URL}/ghost/api/admin/site/" > /dev/null; then
        log_message "Ghost est opérationnel."
        break
    fi

    if [ $i -eq 12 ]; then
        log_message "ATTENTION: Ghost n'est pas complètement opérationnel après 2 minutes."
    else
        sleep 10
    fi
done

log_message "Restauration terminée."