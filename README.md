## Sauvegarde Libvirt/KVM – Scripts prêts à l’emploi

Automatisez la sauvegarde de vos VMs KVM/libvirt en quelques minutes. Deux approches complémentaires:

- `backup-vm.sh`: script bash rapide pour sauvegarder une ou plusieurs VMs (par motif de Title), avec modes liste et simulation.
- `backup_vm.py`: mini-serveur HTTP pour déclencher des backups à la demande via API.

### Caractéristiques
- **Sélection par Title**: ciblez vos VMs via le champ `title` dans l’XML libvirt.
- **Motifs (glob)**: ex. `"VM-*QCOW2"` pour matcher plusieurs VMs.
- **Modes sûrs**: `--list` pour voir, `--fake` pour simuler, pas d’actions destructrices.
- **Arrêt propre**: suspend/redémarre côté bash, stop/start côté Python.
- **Noms de fichiers lisibles**: conserve le nom d’image source et ajoute un timestamp.
- **Logs clairs**: fichiers de log datés par requête.

---

## Prérequis
- Hôte KVM avec libvirt: `qemu-kvm`, `libvirt-daemon`, `virsh`.
- Accès à `virsh`/images (souvent `root`).
- Pour Python: `python3`, `python3-requests`, `python3-libvirt`.

Astuce: vérifiez que chaque VM a un **Title** défini dans son XML libvirt.

```bash
sudo virsh edit NOM_DU_DOMAINE
# Ajoutez au niveau racine si absent
# <title>MonTitreVM</title>
```

---

## backup-vm.sh – Utilisation

### Syntaxe
```bash
./backup-vm.sh [--list] [--fake] <vm_title_ou_motif> <dest_dir>
```

### Options
- `--list` : liste les VMs dont le Title matche, puis quitte (aucune sauvegarde).
- `--fake` : simule les sauvegardes (affiche domaine/title/disque), sans suspendre ni copier.

Si vous ne spécifiez pas de joker (`*`, `?`, `[]`), le script fera une **recherche partielle** automatique (`*texte*`).

### Exemples
- Lister les VMs correspondant à un motif:
```bash
./backup-vm.sh --list "VM-*QCOW2" /backup/kvm
```

- Simuler les sauvegardes (aucune action):
```bash
./backup-vm.sh --fake "VM-*QCOW2" /backup/kvm
```

- Sauvegarder réellement toutes les VMs correspondant au motif:
```bash
./backup-vm.sh "VM-*QCOW2" /backup/kvm
```

### Détails techniques
- Détection des VMs: parcourt `virsh list --all --name`, lit le `Title` via `dominfo` puis fallback via `dumpxml`.
- Disque principal: `virsh domblklist --details` (colonne Device == `disk`).
- Copie: `rsync -avh <disk> <dest_dir>/<nom_image>.YYYY-MM-DD_HH-MM-SS`.
- Logs: `<dest_dir>/backup-<motif>-<timestamp>.log`.

### Bonnes pratiques
- Quotez vos motifs: `"VM-*QCOW2"` pour éviter l’expansion shell.
- Vérifiez l’espace disque de `<dest_dir>`.
- Fenêtre d’indispo: la VM est suspendue pendant la copie (mode réel).

---

## backup_vm.py – API HTTP de backup

### Démarrage
```bash
sudo -E python3 /home/litistech/Scripts/backup_vm.py
```

Par défaut: écoute sur `0.0.0.0:8080`, log local `vm_backup.log`, envoi de webhooks si configuré.

### Endpoints
- Par Title (première VM dont le Title contient la chaîne):
```bash
curl "http://localhost:8080/backup?title=MonTitreVM"
```

- Par motif (toutes les VMs dont le Title contient la chaîne):
```bash
curl "http://localhost:8080/backup?pattern=prod-"
```

### Détails techniques
- Stop VM, copie du disque (sparse), redémarrage.
- Destination par défaut `BACKUP_DIR` (configurable dans le script).
- Nom de fichier: conserve le nom d’image source et ajoute `YYYY-MM-DD_H_M_S`.

### Conseil sécurité
- Limitez l’accès réseau (pare-feu) ou liez à `127.0.0.1` si usage local.

---

## Dépannage
- « Aucune VM trouvée »: vérifiez le `Title` dans l’XML (`virsh dumpxml`), ou élargissez le motif.
- « Disque introuvable »: la VM n’a peut‑être pas de `disk` listé par `domblklist` (devices multiples/nom CI). Adaptez si besoin.
- Permissions: exécutez en `root` pour accès aux images disques.

---

## Feuille de route (idées)
- Support multi‑disques.
- Snapshots à chaud (qemu‑img + blockcommit) pour éviter l’indispo.
- Authentification de l’endpoint HTTP.

---

## Licence
Usage interne; adaptez selon vos besoins.


