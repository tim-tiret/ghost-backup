BACKUP_DIR="/root/ghost/sauv"
DATA_FOLDER="/root/ghost"
RETENTION_DAYS=30
DATE=$(date +%Y-%m-%d_%H-%M-%S)
DB_PASSWORD="ce-mot-de-passe-est-dingue"
GHOST_VOLUME="my_ghost_content"
DB_VOLUME="my_ghost_db"
SITE_URL=https://example.com

# Configuration SFTP (facultative, si vous souhaitez transférer sur un serveur distant)
SFTP_USER="<nom_utilisateur_sftp>"
SFTP_HOST="<adresse_ip_ou_nom_de_domaine_du_serveur_distant>"
SFTP_PORT="<port_sftp>"
SSH_KEY="/chemin/vers/la/cle/ssh"
REMOTE_DIR="/chemin/vers/le/dossier/distant"

mkdir -p "$BACKUP_DIR"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

check_disk_space() {
    local available_space=$(df -P "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 1048576 ]; then
        log_message "ERREUR: Espace disque insuffisant (moins de 1GB disponible)."
        exit 1
    fi
}

cleanup() {
    log_message "Nettoyage des fichiers temporaires..."
    rm -f "$BACKUP_DIR/temp_*"
}

trap cleanup EXIT

cd "$DATA_FOLDER" || exit 1

check_disk_space

log_message "Sauvegarde du volume '$GHOST_VOLUME'..."
GHOST_CONTAINER=$(docker compose ps -q ghost)
DB_CONTAINER=$(docker compose ps -q db)

if [ -z "$GHOST_CONTAINER" ] || [ -z "$DB_CONTAINER" ]; then
    log_message "ERREUR: Les conteneurs ne sont pas en cours d'exécution"
    exit 1
fi

log_message "Sauvegarde de la base de données MySQL..."
docker exec $DB_CONTAINER mysqldump -u root -p$DB_PASSWORD ghost > "$BACKUP_DIR/ghost_db_$DATE.sql"

log_message "Sauvegarde des fichiers Ghost..."
docker run --rm \
    --volumes-from "$GHOST_CONTAINER" \
    -v "$BACKUP_DIR:/backup" \
    ubuntu bash -c "cd /var/lib/ghost && tar czf /backup/ghost_content_$DATE.tar.gz content/"

if [ -f "$DATA_FOLDER/config.production.json" ]; then
    log_message "Sauvegarde de config.production.json..."
    cp "$DATA_FOLDER/config.production.json" "$BACKUP_DIR/config.production_$DATE.json"
fi

if [ ! -f "$BACKUP_DIR/ghost_content_$DATE.tar.gz" ] || [ ! -f "$BACKUP_DIR/ghost_db_$DATE.sql" ]; then
    log_message "ERREUR: Au moins une sauvegarde a échoué."
    exit 1
fi

log_message "Arrêt des conteneurs Ghost..."
docker compose down

log_message "Redémarrage des conteneurs Ghost..."
docker compose up -d

log_message "Nettoyage des anciennes sauvegardes (plus de $RETENTION_DAYS jours)..."
find "$BACKUP_DIR" -name "ghost_content_*.tar.gz" -mtime +$RETENTION_DAYS -delete
find "$BACKUP_DIR" -name "ghost_db_*.sql" -mtime +$RETENTION_DAYS -delete
find "$BACKUP_DIR" -name "config.production_*.json" -mtime +$RETENTION_DAYS -delete

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

# (Facultatif) Envoi des sauvegardes via SFTP
# Décommentez et adaptez si nécessaire
# log_message "Envoi des sauvegardes vers le serveur distant..."
# lftp <<EOF
# open -u $SFTP_USER, sftp://$SFTP_HOST:$SFTP_PORT
# set sftp:connect-program "ssh -o StrictHostKeyChecking=accept-new -a -x -i $SSH_KEY"
# mirror -R $BACKUP_DIR/ $REMOTE_DIR/
# quit
# EOF

log_message "Processus de sauvegarde terminé."