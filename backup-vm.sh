#!/bin/bash
# Usage: ./backup-vm.sh <vm_title> <dest_dir>
# Exemple: ./backup-vm.sh vm1 /backup/kvm

VM_TITLE="$1"
DEST_DIR="$2"

if [ -z "$VM_TITLE" ] || [ -z "$DEST_DIR" ]; then
  echo "Usage: $0 <vm_title> <dest_dir>"
  exit 1
fi

TIMESTAMP=$(date +%F_%H-%M-%S)
LOGFILE="$DEST_DIR/backup-$VM_TITLE-$TIMESTAMP.log"

# Construire un motif: si aucun joker dans l'entrée, faire une recherche partielle
HAS_WILDCARD=false
if echo "$VM_TITLE" | grep -q '[\*\?\[]'; then
  HAS_WILDCARD=true
fi
if $HAS_WILDCARD; then
  MATCH_PATTERN="$VM_TITLE"
else
  MATCH_PATTERN="*$VM_TITLE*"
fi

# Résoudre tous les domaines dont le Title matche le motif
mapfile -t MATCHING_DOMAINS < <(virsh list --all --name | while read -r dom; do
  [ -z "$dom" ] && continue
  title=$(virsh dominfo "$dom" 2>/dev/null | awk -F': ' '/^Title:/{print $2}')
  if [ -z "$title" ]; then
    title=$(virsh dumpxml "$dom" 2>/dev/null | awk -F'[<>]' '/<title>/{print $3; exit}')
  fi
  if [ -n "$title" ] && [[ "$title" == $MATCH_PATTERN ]]; then
    echo "$dom"
  fi
done)

if [ ${#MATCHING_DOMAINS[@]} -eq 0 ]; then
  echo "Erreur: aucune VM trouvée dont le Title matche: $MATCH_PATTERN" | tee -a "$LOGFILE"
  exit 1
fi

# Traiter chaque domaine correspondant
for DOMAIN_NAME in "${MATCHING_DOMAINS[@]}"; do
  # Trouver le disque principal (Device == disk)
  DISK_PATH=$(virsh domblklist "$DOMAIN_NAME" --details | awk '$2=="disk"{print $4; exit}')

  if [ -z "$DISK_PATH" ]; then
    echo "Erreur: impossible de trouver le disque pour le domaine $DOMAIN_NAME (motif Title: $MATCH_PATTERN)" | tee -a "$LOGFILE"
    continue
  fi

  echo "[$(date)] Sauvegarde du domaine $DOMAIN_NAME (motif Title: $MATCH_PATTERN) — disque: $DISK_PATH" | tee -a "$LOGFILE"

  # Pause VM
  virsh suspend "$DOMAIN_NAME"
  echo "[$(date)] VM suspendue: $DOMAIN_NAME" | tee -a "$LOGFILE"

  # Backup avec rsync – conserver le nom de l'image source et suffixer un timestamp
  SRC_NAME="$(basename "$DISK_PATH")"
  BACKUP_FILE="$DEST_DIR/${SRC_NAME}.$TIMESTAMP"
  rsync -avh "$DISK_PATH" "$BACKUP_FILE" >> "$LOGFILE" 2>&1

  echo "[$(date)] Backup terminé: $BACKUP_FILE" | tee -a "$LOGFILE"

  # Reprendre VM
  virsh resume "$DOMAIN_NAME"
  echo "[$(date)] VM reprise: $DOMAIN_NAME" | tee -a "$LOGFILE"
done
