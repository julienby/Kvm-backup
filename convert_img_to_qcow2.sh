#!/bin/bash
# Usage: ./convert_img_to_qcow2.sh [--list] [--fake] <vm_title_or_pattern> <dest_dir>
# Exemple: ./convert_img_to_qcow2.sh --list "VM-*" /var/lib/libvirt/images

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

mkdir -p "$DEST_DIR" || {
  echo "Erreur: impossible de créer le répertoire destination: $DEST_DIR" >&2
  exit 1
}

TIMESTAMP=$(date +%F_%H-%M-%S)
LOGFILE="$DEST_DIR/convert-qcow2-$TIMESTAMP.log"

# Construire un motif: si aucun joker dans l'entrée, faire une correspondance exacte
HAS_WILDCARD=false
if echo "$VM_TITLE" | grep -q '[\*\?\[]'; then
  HAS_WILDCARD=true
fi
if $HAS_WILDCARD; then
  MATCH_PATTERN="$VM_TITLE"
else
  MATCH_PATTERN="$VM_TITLE"
fi

# Résoudre tous les domaines dont le Title matche le motif
mapfile -t MATCHING_DOMAINS < <(virsh list --all --name | while read -r dom; do
  [ -z "$dom" ] && continue
  title=$(virsh dominfo "$dom" 2>/dev/null | awk -F': ' '/^Title:/{print $2}')
  if [ -z "$title" ]; then
    title=$(virsh dumpxml "$dom" 2>/dev/null | awk -F'[<>]' '/<title>/{print $3; exit}')
  fi
  if [ -n "$title" ] && {
    if $HAS_WILDCARD; then
      [[ "$title" == $MATCH_PATTERN ]]
    else
      [ "$title" = "$MATCH_PATTERN" ]
    fi
  }; then
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

wait_for_state() {
  local domain="$1"
  local target_state="$2"   # running|shut off|paused
  local timeout_sec="$3"
  local start_ts=$(date +%s)
  while true; do
    state=$(virsh domstate "$domain" 2>/dev/null | tr -d '\r')
    [ "$state" = "$target_state" ] && return 0
    now=$(date +%s)
    if [ $((now - start_ts)) -ge "$timeout_sec" ]; then
      return 1
    fi
    sleep 1
  done
}

replace_disk_path_in_xml() {
  local xml_in="$1"
  local xml_out="$2"
  local old_path="$3"
  local new_path="$4"
  # Remplacer le premier <disk device='disk'> source file="..." par new_path
  # On agit prudemment: remplace seulement l'attribut file correspondant à old_path
  awk -v old="${old_path}" -v rep="${new_path}" '
    BEGIN { replaced = 0 }
    {
      line = $0
      if (replaced == 0) {
        if (line ~ /<source[[:space:]]+file=/) {
          pos = index(line, "file=")
          if (pos > 0) {
            qchar = substr(line, pos + 5, 1)
            if (qchar == "\"" || qchar == sprintf("%c", 39)) {
              start = pos + 6
              rest = substr(line, start)
              endrel = index(rest, qchar)
              if (endrel > 0) {
                path = substr(rest, 1, endrel - 1)
                if (path == old) {
                  # reconstruire la ligne avec rep, en conservant le quote d origine
                  line = substr(line, 1, start - 1) rep substr(line, start + endrel - 1)
                  replaced = 1
                }
              }
            }
          }
        }
      }
      print line
    }
  ' "$xml_in" > "$xml_out.tmp1"

  # Deuxième passage: si le bloc <disk> contient la nouvelle source, forcer driver type="qcow2"
  awk -v target="${new_path}" '
    function flush_block() {
      if (inDisk) {
        if (hasTarget) {
          for (i = 1; i <= blkLen; i++) {
            if (block[i] ~ /<driver[[:space:]][^>]*type="[^"]*"/) {
              gsub(/type="[^"]*"/, "type=\"qcow2\"", block[i])
            }
          }
        }
        for (i = 1; i <= blkLen; i++) print block[i]
        inDisk = 0; blkLen = 0; hasTarget = 0
      }
    }
    BEGIN { inDisk = 0; blkLen = 0; hasTarget = 0 }
    {
      line = $0
      if (!inDisk) {
        if (line ~ /<disk\b/) {
          inDisk = 1; blkLen = 0; hasTarget = 0
          block[++blkLen] = line
        } else {
          print line
        }
      } else {
        block[++blkLen] = line
        if (line ~ /<source[[:space:]]+file=/ && line ~ target) {
          hasTarget = 1
        }
        if (line ~ /<\/disk>/) {
          flush_block()
        }
      }
    }
    END { if (inDisk) flush_block() }
  ' "$xml_out.tmp1" > "$xml_out"
  rm -f "$xml_out.tmp1"
  return 0
}

# Traiter chaque domaine correspondant
for entry in "${MATCHING_DOMAINS[@]}"; do
  DOMAIN_NAME="${entry%%|*}"
  TITLE_FOUND="${entry##*|}"

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

  # 1/ Arrêter la VM si elle fonctionne
  current_state=$(virsh domstate "$DOMAIN_NAME" 2>/dev/null | tr -d '\r')
  if [ "$current_state" = "running" ] || [ "$current_state" = "paused" ]; then
    echo "[$(date)] Arrêt de la VM $DOMAIN_NAME (état actuel: $current_state)" | tee -a "$LOGFILE"
    virsh shutdown "$DOMAIN_NAME" >/dev/null 2>&1 || true
    if ! wait_for_state "$DOMAIN_NAME" "shut off" 60; then
      echo "[$(date)] Arrêt gracieux trop long, forcer l'arrêt (destroy)" | tee -a "$LOGFILE"
      virsh destroy "$DOMAIN_NAME" >/dev/null 2>&1 || true
      wait_for_state "$DOMAIN_NAME" "shut off" 10 || true
    fi
  else
    echo "[$(date)] VM déjà arrêtée: $DOMAIN_NAME (état: $current_state)" | tee -a "$LOGFILE"
  fi

  # 2/ Convertir le disque en qcow2
  src_base=$(basename "$DISK_PATH")
  dest_name_noext="${src_base%.*}"
  NEW_IMG="$DEST_DIR/${dest_name_noext}.qcow2"
  # éviter l'écrasement
  if [ -e "$NEW_IMG" ]; then
    NEW_IMG="$DEST_DIR/${dest_name_noext}.$TIMESTAMP.qcow2"
  fi

  echo "[$(date)] Conversion vers QCOW2: $DISK_PATH -> $NEW_IMG" | tee -a "$LOGFILE"
  if ! qemu-img convert -p -O qcow2 "$DISK_PATH" "$NEW_IMG" >> "$LOGFILE" 2>&1; then
    echo "Erreur: échec de qemu-img convert pour $DOMAIN_NAME" | tee -a "$LOGFILE"
    continue
  fi

  # 3/ Modifier le path dans le XML vers la nouvelle image
  TMP_XML="/tmp/${DOMAIN_NAME}-${TIMESTAMP}.xml"
  NEW_XML="/tmp/${DOMAIN_NAME}-${TIMESTAMP}.new.xml"
  if ! virsh dumpxml "$DOMAIN_NAME" > "$TMP_XML" 2>>"$LOGFILE"; then
    echo "Erreur: échec dumpxml pour $DOMAIN_NAME" | tee -a "$LOGFILE"
    continue
  fi

  if ! replace_disk_path_in_xml "$TMP_XML" "$NEW_XML" "$DISK_PATH" "$NEW_IMG"; then
    echo "Erreur: échec de mise à jour XML pour $DOMAIN_NAME" | tee -a "$LOGFILE"
    rm -f "$TMP_XML" "$NEW_XML"
    continue
  fi

  if ! virsh define "$NEW_XML" >> "$LOGFILE" 2>&1; then
    echo "Erreur: échec de virsh define avec le nouveau XML pour $DOMAIN_NAME" | tee -a "$LOGFILE"
    rm -f "$TMP_XML" "$NEW_XML"
    continue
  fi
  rm -f "$TMP_XML" "$NEW_XML"
  echo "[$(date)] XML mis à jour pour $DOMAIN_NAME" | tee -a "$LOGFILE"

  # 4/ Redémarrer la VM
  if ! virsh start "$DOMAIN_NAME" >> "$LOGFILE" 2>&1; then
    echo "Attention: impossible de démarrer la VM $DOMAIN_NAME. Veuillez vérifier manuellement." | tee -a "$LOGFILE"
  else
    echo "[$(date)] VM démarrée: $DOMAIN_NAME" | tee -a "$LOGFILE"
  fi
done

echo "[$(date)] Terminé. Log: $LOGFILE"



