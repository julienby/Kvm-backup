#!/bin/bash
# Usage: ./backup-vm.sh [--list] [--fake] <vm_title_or_pattern> <dest_dir>
# Exemple: ./backup-vm.sh --list "VM-*QCOW2" /backup/kvm

FAKE=false
LIST=false

# Parser les flags simples en tête
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --fake)
      FAKE=true
      ;;
    --list)
      LIST=true
      ;;
    --)
      ;;
    --*)
      echo "Option inconnue: $arg" >&2
      exit 2
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

VM_TITLE="${ARGS[0]}"
DEST_DIR="${ARGS[1]}"

if [ -z "$VM_TITLE" ] || [ -z "$DEST_DIR" ]; then
  echo "Usage: $0 [--list] [--fake] <vm_title_or_pattern> <dest_dir>"
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
    echo "$dom|$title"
  fi
done)

if [ ${#MATCHING_DOMAINS[@]} -eq 0 ]; then
  echo "Erreur: aucune VM trouvée dont le Title matche: $MATCH_PATTERN" | tee -a "$LOGFILE"
  exit 1
fi

# Mode --list: afficher les domaines et Titles, puis quitter
if $LIST; then
  echo "Correspondances (Title -> domaine):"
  for entry in "${MATCHING_DOMAINS[@]}"; do
    dom="${entry%%|*}"
    title="${entry##*|}"
    echo "- $title -> $dom"
  done
  exit 0
fi

# Traiter chaque domaine correspondant
for entry in "${MATCHING_DOMAINS[@]}"; do
  DOMAIN_NAME="${entry%%|*}"
  TITLE_FOUND="${entry##*|}"
  # Trouver le disque principal (Device == disk)
  DISK_PATH=$(virsh domblklist "$DOMAIN_NAME" --details | awk '$2=="disk"{print $4; exit}')

  if [ -z "$DISK_PATH" ]; then
    echo "Erreur: impossible de trouver le disque pour le domaine $DOMAIN_NAME (motif Title: $MATCH_PATTERN)" | tee -a "$LOGFILE"
    continue
  fi

  echo "[$(date)] Cible: domaine=$DOMAIN_NAME, title=$TITLE_FOUND, disque=$DISK_PATH" | tee -a "$LOGFILE"

  if $FAKE; then
    echo "[$(date)] Mode --fake: aucune action réalisée pour $DOMAIN_NAME" | tee -a "$LOGFILE"
    continue
  fi

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
