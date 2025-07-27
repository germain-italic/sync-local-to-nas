#!/bin/bash

# Script de synchronisation NAS
# Synchronise les dossiers sources vers le NAS de destination

set -e

# Chargement de la configuration depuis .env
if [ ! -f .env ]; then
    echo "Erreur: Le fichier .env n'existe pas. Créez-le à partir de .env.example"
    exit 1
fi

# Chargement des variables d'environnement
set -a
source .env
set +a

# Validation des variables requises
if [ -z "$NAS_HOST" ] || [ -z "$DESTINATION" ]; then
    echo "Erreur: Variables manquantes dans .env (NAS_HOST, DESTINATION)"
    exit 1
fi

# Récupération de tous les dossiers SOURCE_* dans l'ordre numérique
SOURCE_ARRAY=()
for var in $(env | grep '^SOURCE_[0-9]' | sort -V | cut -d= -f1); do
    SOURCE_ARRAY+=("${!var}")
done

# Vérification qu'au moins un dossier source est défini
if [ ${#SOURCE_ARRAY[@]} -eq 0 ]; then
    echo "Erreur: Aucun dossier source défini (utilisez SOURCE_1, SOURCE_2, etc.)"
    exit 1
fi

# Configuration
FULL_DESTINATION="$NAS_HOST:$DESTINATION"
LOG_FILE="/tmp/sync_nas.log"
MAX_ATTEMPTS=${MAX_ATTEMPTS:-3}

# Vérification des dossiers source
for source in "${SOURCE_ARRAY[@]}"; do
    if [ ! -d "$source" ]; then
        echo "Erreur: Le dossier source $source n'existe pas"
        exit 1
    fi
done

echo "$(date): Début de la synchronisation" | tee -a "$LOG_FILE"

# Options rsync:
# -a : mode archive (récursif, préserve les liens, etc.)
# -v : verbose
# -c : utilise checksum au lieu de time/size
# -S : sparse files
# --partial : garde les fichiers partiels
# --progress : affiche le progrès
# --log-file : fichier de log
# -e ssh : utilise SSH pour la connexion
SSH_OPTS="ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o ConnectTimeout=30"
RSYNC_OPTS="-avcS --partial --progress --log-file=$LOG_FILE -e $RSYNC_EXTRA_OPTS"

# Fonction de retry avec backoff exponentiel
sync_with_retry() {
    local source="$1"
    local destination="$2"
    local exclude_opts="$3"
    local attempt=1
    
    while [ $attempt -le $MAX_ATTEMPTS ]; do
        echo "Tentative $attempt/$MAX_ATTEMPTS pour $source"
        if rsync $RSYNC_OPTS "$SSH_OPTS" $exclude_opts "$source" "$destination"; then
            echo "Synchronisation réussie pour $source"
            return 0
        else
            echo "Échec de la synchronisation (tentative $attempt/$MAX_ATTEMPTS)"
            if [ $attempt -lt $MAX_ATTEMPTS ]; then
                local wait_time=$((attempt * 30))
                echo "Attente de ${wait_time}s avant la prochaine tentative..."
                sleep $wait_time
            fi
            attempt=$((attempt + 1))
        fi
    done
    
    echo "ERREUR: Synchronisation échouée après $MAX_ATTEMPTS tentatives pour $source"
    return 1
}

# Synchronisation de tous les dossiers source
for i in "${!SOURCE_ARRAY[@]}"; do
    source="${SOURCE_ARRAY[$i]}"
    echo "Synchronisation de $source vers $FULL_DESTINATION"
    sync_with_retry "$source" "$FULL_DESTINATION" ""
done

echo "$(date): Synchronisation terminée" | tee -a "$LOG_FILE"
echo "Log disponible dans: $LOG_FILE"
