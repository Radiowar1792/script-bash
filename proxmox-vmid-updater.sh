#!/bin/bash

set -euo pipefail

# ============================================================
# PROXMOX VMID UPDATER - Script Personnalisé
# Version: 2.2 (Bugfix NODE_ASSIGNED + Rollback + Dry-run)
# ============================================================

# ─────────────────────────────────────────
# 📁 CONFIGURATION DES LOGS
# ─────────────────────────────────────────
LOGDIR="/var/log/proxmox-vmid-updater"
LOGFILE="$LOGDIR/rename-vmid-$(date '+%Y%m%d_%H%M%S').log"
mkdir -p "$LOGDIR"
touch "$LOGFILE"

# Mode dry-run (simulation)
DRY_RUN=false

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() {
    local level="$1"
    shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $*" >> "$LOGFILE"
    case "$level" in
        INFO)    echo -e "${CYAN}[INFO]${NC} $*" ;;
        SUCCESS) echo -e "${GREEN}[OK]${NC} $*" ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} $*" ;;
        ERROR)   echo -e "${RED}[ERROR]${NC} $*" >&2 ;;
        DRYRUN)  echo -e "${YELLOW}[DRY-RUN]${NC} $*" ;;
    esac
}

log_separator() {
    echo "─────────────────────────────────────────────────────" | tee -a "$LOGFILE"
}

# ─────────────────────────────────────────
# 🔒 VÉRIFICATION ROOT
# ─────────────────────────────────────────
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo -e "${RED}Ce script doit être exécuté en tant que root!${NC}" >&2
        exit 1
    fi
    log "INFO" "Exécution root confirmée"
}

# ─────────────────────────────────────────
# 📦 VÉRIFICATION DES DÉPENDANCES
# ─────────────────────────────────────────
check_dependencies() {
    local NEEDS=()
    for cmd in dialog pvesh; do
        command -v "$cmd" > /dev/null 2>&1 || NEEDS+=("$cmd")
    done

    if (( ${#NEEDS[@]} > 0 )); then
        log "WARN" "Paquets manquants: ${NEEDS[*]}"
        read -rp "Installer via apt? [O/n] " ans
        ans=${ans:-O}
        if [[ "$ans" =~ ^[OoYy]$ ]]; then
            apt update && apt install -y "${NEEDS[@]}"
            log "SUCCESS" "Dépendances installées"
        else
            log "ERROR" "Dépendances manquantes - abandon"
            exit 1
        fi
    else
        log "SUCCESS" "Toutes les dépendances sont présentes"
    fi
}

# ─────────────────────────────────────────
# 🖥️ BANNIÈRE
# ─────────────────────────────────────────
show_banner() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║        PROXMOX VMID UPDATER - v2.2                  ║"
    echo "║     Changement d'IDs LXC/VM sur noeuds Proxmox      ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${YELLOW}Log: $LOGFILE${NC}"
    echo ""
}

# ─────────────────────────────────────────
# ⚠️ AVERTISSEMENT
# ─────────────────────────────────────────
show_warning() {
    dialog --title "AVERTISSEMENT" \
        --yes-label "Je comprends, Continuer" \
        --no-label "Annuler" \
        --yesno "\
ATTENTION IMPORTANTE

Ce script modifie les VMIDs Proxmox (LXC et VM).

RISQUES POTENTIELS:
  - Corruption de config si mal utilisé
  - Perte de données si VM en cours d'execution
  - Problemes de cluster si pas de quorum

PRECAUTIONS PRISES:
  - Verification que la VM/LXC est arretee
  - Sauvegarde automatique des configs
  - Rollback automatique en cas d'erreur
  - Logs detailles de toutes les operations

AVANT DE CONTINUER:
  - Faites un snapshot/backup de vos VMs
  - Assurez-vous que les VMs sont arretees
  - Verifiez que le cluster est en bonne sante" \
        22 60 || { log "INFO" "Annulé par utilisateur"; clear; exit 0; }

    log "INFO" "Avertissements acceptés"
}

# ─────────────────────────────────────────
# 🌐 DÉTECTION DES NOEUDS
# ─────────────────────────────────────────
detect_cluster_nodes() {
    CLUSTER_NODES=()

    if pvecm nodes &>/dev/null 2>&1; then
        while IFS= read -r node; do
            [[ -n "$node" ]] && CLUSTER_NODES+=("$node")
        done < <(pvesh get /nodes --output-format=json 2>/dev/null \
            | grep -Po '"node"\s*:\s*"\K[^"]+')
        log "INFO" "Cluster détecté - Noeuds: ${CLUSTER_NODES[*]}"
    fi

    if (( ${#CLUSTER_NODES[@]} == 0 )); then
        local THIS_NODE
        THIS_NODE=$(hostname -s)
        CLUSTER_NODES=("$THIS_NODE")
        log "INFO" "Mode standalone - Noeud: $THIS_NODE"
    fi
}

# ─────────────────────────────────────────
# 🔗 VÉRIFICATION DU QUORUM
# ─────────────────────────────────────────
check_quorum() {
    if (( ${#CLUSTER_NODES[@]} <= 1 )); then
        log "INFO" "Standalone - vérification quorum ignorée"
        return 0
    fi

    local QSTAT
    QSTAT=$(pvecm status 2>/dev/null | awk -F: '/Quorate:/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2
    }' || echo "No")

    if [[ "$QSTAT" != "Yes" ]]; then
        dialog --title "Pas de Quorum" \
            --msgbox "Le cluster n'a pas le quorum.\nVeuillez restaurer le quorum avant de continuer." \
            8 55
        log "ERROR" "Pas de quorum - abandon"
        clear
        exit 1
    fi

    log "SUCCESS" "Quorum cluster OK"
}

# ─────────────────────────────────────────
# 📋 LISTER LES VMs/LXCs
# ─────────────────────────────────────────
list_all_vms() {
    log "INFO" "Liste de toutes les VMs/LXCs"
    local list_content=""

    for NODE in "${CLUSTER_NODES[@]}"; do
        list_content+="=== Noeud: $NODE ===\n"

        local qemu_ids
        qemu_ids=$(pvesh get "/nodes/$NODE/qemu" --output-format=json 2>/dev/null \
            | grep -Po '"vmid"\s*:\s*\K[0-9]+' || true)

        if [[ -n "$qemu_ids" ]]; then
            while IFS= read -r vmid; do
                local name status
                name=$(pvesh get "/nodes/$NODE/qemu/$vmid/config" \
                    --output-format=json 2>/dev/null \
                    | grep -Po '"name"\s*:\s*"\K[^"]+' | head -1 || echo "N/A")
                status=$(pvesh get "/nodes/$NODE/qemu/$vmid/status/current" \
                    --output-format=json 2>/dev/null \
                    | grep -Po '"status"\s*:\s*"\K[^"]+' | head -1 || echo "unknown")
                list_content+="  [QEMU] ID: $vmid | Nom: $name | Status: $status\n"
            done <<< "$qemu_ids"
        fi

        local lxc_ids
        lxc_ids=$(pvesh get "/nodes/$NODE/lxc" --output-format=json 2>/dev/null \
            | grep -Po '"vmid"\s*:\s*\K[0-9]+' || true)

        if [[ -n "$lxc_ids" ]]; then
            while IFS= read -r vmid; do
                local name status
                name=$(pvesh get "/nodes/$NODE/lxc/$vmid/config" \
                    --output-format=json 2>/dev/null \
                    | grep -Po '"hostname"\s*:\s*"\K[^"]+' | head -1 || echo "N/A")
                status=$(pvesh get "/nodes/$NODE/lxc/$vmid/status/current" \
                    --output-format=json 2>/dev/null \
                    | grep -Po '"status"\s*:\s*"\K[^"]+' | head -1 || echo "unknown")
                list_content+="  [LXC]  ID: $vmid | Nom: $name | Status: $status\n"
            done <<< "$lxc_ids"
        fi

        list_content+="\n"
    done

    [[ -z "$list_content" ]] && list_content="Aucune VM ou LXC trouvée."

    dialog --title "VMs et LXCs disponibles" \
        --msgbox "$(echo -e "$list_content")" \
        30 80
}

# ─────────────────────────────────────────
# 🔍 RECHERCHER UN VMID
# ─────────────────────────────────────────
# ⚠️  NE PAS appeler depuis un subshell $() !
#     Les variables globales NODE_ASSIGNED et TYPE
#     doivent être capturées IMMÉDIATEMENT après l'appel.
# ─────────────────────────────────────────
find_vmid() {
    local ID_SEARCH="$1"

    # Reset explicite des globales
    NODE_ASSIGNED=""
    TYPE=""

    for N in "${CLUSTER_NODES[@]}"; do
        if pvesh get "/nodes/$N/qemu/$ID_SEARCH/config" \
               --output-format=json &>/dev/null 2>&1; then
            TYPE="qemu"
            NODE_ASSIGNED="$N"
            log "SUCCESS" "VM QEMU $ID_SEARCH trouvée sur $N"
            return 0
        fi
    done

    for N in "${CLUSTER_NODES[@]}"; do
        if pvesh get "/nodes/$N/lxc/$ID_SEARCH/config" \
               --output-format=json &>/dev/null 2>&1; then
            TYPE="lxc"
            NODE_ASSIGNED="$N"
            log "SUCCESS" "LXC $ID_SEARCH trouvée sur $N"
            return 0
        fi
    done

    log "WARN" "VMID $ID_SEARCH non trouvé sur aucun noeud"
    NODE_ASSIGNED=""
    TYPE=""
    return 1
}

# ─────────────────────────────────────────
# 🛑 VÉRIFIER QUE LA VM EST ARRÊTÉE
# ─────────────────────────────────────────
check_vm_stopped() {
    local node="$1"
    local vmid="$2"
    local type="$3"
    local status

    status=$(pvesh get "/nodes/$node/$type/$vmid/status/current" \
        --output-format=json 2>/dev/null \
        | grep -Po '"status"\s*:\s*"\K[^"]+' | head -1 || echo "unknown")

    log "INFO" "Status $type $vmid sur $node: $status"
    [[ "$status" == "stopped" ]]
}

# ─────────────────────────────────────────
# 📸 VÉRIFIER LES SNAPSHOTS
# ─────────────────────────────────────────
check_snapshots() {
    local node="$1"
    local vmid="$2"
    local type="$3"

    local snaps
    snaps=$(pvesh get "/nodes/$node/$type/$vmid/snapshot" \
        --output-format=json 2>/dev/null \
        | grep -Po '"name"\s*:\s*"\K[^"]+' \
        | grep -v "^current$" || true)

    if [[ -n "$snaps" ]]; then
        local snap_count
        snap_count=$(echo "$snaps" | wc -l)
        log "WARN" "$type $vmid a $snap_count snapshot(s): $(echo "$snaps" | tr '\n' ' ')"

        dialog --title "Snapshots détectés" \
            --yes-label "Continuer quand même" \
            --no-label "Annuler" \
            --yesno "\
Attention: $type $vmid possède $snap_count snapshot(s):

$(echo "$snaps" | sed 's/^/  - /')

Les snapshots NE SERONT PAS renommés automatiquement.
Cela peut causer des incohérences.

Voulez-vous continuer malgré tout?" \
            18 60 || return 1
    fi

    return 0
}

# ─────────────────────────────────────────
# 💾 SAUVEGARDER LA CONFIG
# ─────────────────────────────────────────
backup_config() {
    local node="$1"
    local vmid="$2"
    local type="$3"
    local BACKUP_DIR="/var/lib/proxmox-vmid-backups"
    local BACKUP_FILE="$BACKUP_DIR/${type}_${vmid}_$(date '+%Y%m%d_%H%M%S').conf.bak"
    local CONFIG_PATH

    mkdir -p "$BACKUP_DIR"

    if [[ "$type" == "qemu" ]]; then
        CONFIG_PATH="/etc/pve/nodes/$node/qemu-server/$vmid.conf"
    else
        CONFIG_PATH="/etc/pve/nodes/$node/lxc/$vmid.conf"
    fi

    if [[ -f "$CONFIG_PATH" ]]; then
        cp "$CONFIG_PATH" "$BACKUP_FILE"
        log "SUCCESS" "Config sauvegardée: $BACKUP_FILE"
        echo "$BACKUP_FILE"
    else
        log "WARN" "Config non trouvée pour backup: $CONFIG_PATH"
        echo ""
    fi
}

# ─────────────────────────────────────────
# ↩️  ROLLBACK
# ─────────────────────────────────────────
rollback_rename() {
    local ID_OLD="$1"
    local ID_NEW="$2"
    local TYPE="$3"
    local NODE="$4"
    local BACKUP_FILE="$5"
    local LOCAL_NODE
    LOCAL_NODE=$(hostname -s)

    log "WARN" "=== ROLLBACK: $TYPE $ID_NEW → $ID_OLD sur $NODE ==="

    local CONF_DIR CONF_NEW CONF_OLD
    if [[ "$TYPE" == "qemu" ]]; then
        CONF_DIR="/etc/pve/nodes/$NODE/qemu-server"
    else
        CONF_DIR="/etc/pve/nodes/$NODE/lxc"
    fi
    CONF_NEW="$CONF_DIR/$ID_NEW.conf"
    CONF_OLD="$CONF_DIR/$ID_OLD.conf"

    # Restaurer depuis backup si dispo
    if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
        if [[ "$NODE" == "$LOCAL_NODE" ]]; then
            cp "$BACKUP_FILE" "$CONF_OLD"
            rm -f "$CONF_NEW"
            log "SUCCESS" "Config restaurée depuis backup: $BACKUP_FILE"
        else
            scp "$BACKUP_FILE" "root@$NODE:$CONF_OLD" &>/dev/null
            ssh -o StrictHostKeyChecking=no "root@$NODE" "rm -f '$CONF_NEW'"
            log "SUCCESS" "Config distante restaurée depuis backup"
        fi
    else
        # Pas de backup: tenter de renommer en sens inverse
        if [[ -f "$CONF_NEW" ]]; then
            if [[ "$NODE" == "$LOCAL_NODE" ]]; then
                mv "$CONF_NEW" "$CONF_OLD"
                sed -i "s|/$ID_NEW/|/$ID_OLD/|g" "$CONF_OLD"
                sed -i "s|-$ID_NEW-|-$ID_OLD-|g" "$CONF_OLD"
                sed -i "s|:$ID_NEW/|:$ID_OLD/|g" "$CONF_OLD"
            else
                ssh -o StrictHostKeyChecking=no "root@$NODE" \
                    "mv '$CONF_NEW' '$CONF_OLD' && \
                     sed -i 's|/$ID_NEW/|/$ID_OLD/|g' '$CONF_OLD' && \
                     sed -i 's|-$ID_NEW-|-$ID_OLD-|g' '$CONF_OLD' && \
                     sed -i 's|:$ID_NEW/|:$ID_OLD/|g' '$CONF_OLD'"
            fi
            log "SUCCESS" "Config renommée en sens inverse (sans backup)"
        fi
    fi

    # Rollback volumes de stockage
    log "WARN" "Rollback des volumes: $ID_NEW → $ID_OLD"
    rename_storage_volumes "$ID_NEW" "$ID_OLD" "$NODE"

    log "WARN" "=== ROLLBACK TERMINÉ ==="
}

# ─────────────────────────────────────────
# 💽 RENOMMER LES VOLUMES DE STOCKAGE
#    Gère local, ZFS et Ceph
# ─────────────────────────────────────────
rename_storage_volumes() {
    local ID_OLD="$1"
    local ID_NEW="$2"
    local NODE="$3"
    local LOCAL_NODE
    LOCAL_NODE=$(hostname -s)

    log "INFO" "Renommage des volumes: $ID_OLD → $ID_NEW sur $NODE"

    _do_rename_volumes() {
        local search_dirs=("/var/lib/vz" "/mnt/pve")

        for base_dir in "${search_dirs[@]}"; do
            [[ ! -d "$base_dir" ]] && continue

            # Dossiers
            while IFS= read -r found_dir; do
                local new_dir="${found_dir//$ID_OLD/$ID_NEW}"
                if [[ "$found_dir" != "$new_dir" ]]; then
                    if [[ "$DRY_RUN" == "true" ]]; then
                        log "DRYRUN" "mv dossier: $found_dir → $new_dir"
                    else
                        mv "$found_dir" "$new_dir"
                        log "SUCCESS" "Dossier: $found_dir → $new_dir"
                    fi
                fi
            done < <(find "$base_dir" -maxdepth 5 -type d -name "*${ID_OLD}*" 2>/dev/null || true)

            # Fichiers
            while IFS= read -r found_file; do
                local new_file="${found_file//$ID_OLD/$ID_NEW}"
                if [[ "$found_file" != "$new_file" ]]; then
                    if [[ "$DRY_RUN" == "true" ]]; then
                        log "DRYRUN" "mv fichier: $found_file → $new_file"
                    else
                        mv "$found_file" "$new_file"
                        log "SUCCESS" "Fichier: $found_file → $new_file"
                    fi
                fi
            done < <(find "$base_dir" -maxdepth 5 -type f -name "*${ID_OLD}*" 2>/dev/null || true)
        done
    }

    # ── ZFS ──
    _rename_zfs_volumes() {
        if command -v zfs &>/dev/null; then
            while IFS= read -r zvol; do
                local new_zvol="${zvol//$ID_OLD/$ID_NEW}"
                if [[ "$zvol" != "$new_zvol" ]]; then
                    if [[ "$DRY_RUN" == "true" ]]; then
                        log "DRYRUN" "zfs rename: $zvol → $new_zvol"
                    else
                        zfs rename "$zvol" "$new_zvol" \
                            && log "SUCCESS" "ZFS: $zvol → $new_zvol" \
                            || log "WARN" "ZFS rename échoué: $zvol"
                    fi
                fi
            done < <(zfs list -H -o name 2>/dev/null | grep "$ID_OLD" || true)
        fi
    }

    # ── Ceph RBD ──
    _rename_ceph_volumes() {
        if command -v rbd &>/dev/null; then
            local pools
            pools=$(ceph osd pool ls 2>/dev/null || true)
            while IFS= read -r pool; do
                while IFS= read -r img; do
                    local new_img="${img//$ID_OLD/$ID_NEW}"
                    if [[ "$img" != "$new_img" ]]; then
                        if [[ "$DRY_RUN" == "true" ]]; then
                            log "DRYRUN" "rbd mv: $pool/$img → $pool/$new_img"
                        else
                            rbd mv "$pool/$img" "$pool/$new_img" \
                                && log "SUCCESS" "Ceph RBD: $pool/$img → $pool/$new_img" \
                                || log "WARN" "RBD rename échoué: $pool/$img"
                        fi
                    fi
                done < <(rbd ls "$pool" 2>/dev/null | grep "$ID_OLD" || true)
            done <<< "$pools"
        fi
    }

    if [[ "$NODE" == "$LOCAL_NODE" ]]; then
        _do_rename_volumes
        _rename_zfs_volumes
        _rename_ceph_volumes
    else
        ssh -o StrictHostKeyChecking=no "root@$NODE" \
            "find /var/lib/vz /mnt/pve -maxdepth 5 \
             \( -name '*${ID_OLD}*' \) 2>/dev/null | \
             while IFS= read -r f; do \
                 nf=\"\${f//$ID_OLD/$ID_NEW}\"; \
                 [ \"\$f\" != \"\$nf\" ] && mv \"\$f\" \"\$nf\" && echo \"Renommé: \$f\"; \
             done || true" 2>/dev/null \
            && log "SUCCESS" "Volumes distants renommés sur $NODE" \
            || log "WARN" "Erreur volumes distants sur $NODE (non bloquant)"

        # ZFS distant
        ssh -o StrictHostKeyChecking=no "root@$NODE" \
            "command -v zfs &>/dev/null && \
             zfs list -H -o name 2>/dev/null | grep '$ID_OLD' | \
             while IFS= read -r z; do \
                 nz=\"\${z//$ID_OLD/$ID_NEW}\"; \
                 [ \"\$z\" != \"\$nz\" ] && zfs rename \"\$z\" \"\$nz\" && echo \"ZFS: \$z\"; \
             done || true" 2>/dev/null || true
    fi

    log "INFO" "Renommage volumes terminé"
}

# ─────────────────────────────────────────
# 🔄 RENOMMER UN VMID
# ─────────────────────────────────────────
rename_vmid() {
    local ID_OLD="$1"
    local ID_NEW="$2"
    local TYPE="$3"     # passé explicitement - NE PAS utiliser $TYPE global
    local NODE="$4"     # passé explicitement - NE PAS utiliser $NODE_ASSIGNED global
    local LOCAL_NODE
    LOCAL_NODE=$(hostname -s)
    local CONF_DIR CONF_OLD CONF_NEW

    log_separator
    log "INFO" "Renommage: $TYPE $ID_OLD → $ID_NEW sur $NODE"

    # ── Validation des paramètres ──
    if [[ -z "$TYPE" ]]; then
        log "ERROR" "TYPE vide - abandon sécurisé"
        return 1
    fi
    if [[ -z "$NODE" ]]; then
        log "ERROR" "NODE vide - abandon sécurisé"
        return 1
    fi

    if [[ "$TYPE" == "qemu" ]]; then
        CONF_DIR="/etc/pve/nodes/$NODE/qemu-server"
    else
        CONF_DIR="/etc/pve/nodes/$NODE/lxc"
    fi

    CONF_OLD="$CONF_DIR/$ID_OLD.conf"
    CONF_NEW="$CONF_DIR/$ID_NEW.conf"

    log "INFO" "Config attendue: $CONF_OLD"

    if [[ ! -f "$CONF_OLD" ]]; then
        log "ERROR" "Config introuvable: $CONF_OLD"
        dialog --title "Erreur" \
            --msgbox "Config introuvable:\n$CONF_OLD\n\nVérifiez:\n  - NODE: '$NODE'\n  - TYPE: '$TYPE'\n  - VMID: $ID_OLD" \
            10 65
        return 1
    fi

    # ── Dry-run : simulation uniquement ──
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRYRUN" "cp $CONF_OLD → $CONF_NEW"
        log "DRYRUN" "sed références $ID_OLD → $ID_NEW dans config"
        log "DRYRUN" "rename_storage_volumes $ID_OLD → $ID_NEW"
        log "DRYRUN" "rm $CONF_OLD"
        log "DRYRUN" "=== Simulation terminée (aucune modification effectuée) ==="
        return 0
    fi

    # ── Exécution réelle ──
    if [[ "$NODE" == "$LOCAL_NODE" ]]; then
        log "INFO" "Renommage LOCAL sur $NODE"

        cp "$CONF_OLD" "$CONF_NEW" \
            || { log "ERROR" "Echec copie config"; return 1; }
        log "SUCCESS" "Config copiée: $ID_OLD.conf → $ID_NEW.conf"

        sed -i "s|/$ID_OLD/|/$ID_NEW/|g" "$CONF_NEW"
        sed -i "s|-$ID_OLD-|-$ID_NEW-|g" "$CONF_NEW"
        sed -i "s|:$ID_OLD/|:$ID_NEW/|g" "$CONF_NEW"
        log "INFO" "Références internes mises à jour"

        rename_storage_volumes "$ID_OLD" "$ID_NEW" "$NODE"

        rm -f "$CONF_OLD"
        log "SUCCESS" "Ancienne config supprimée: $CONF_OLD"

    else
        log "INFO" "Renommage DISTANT sur $NODE via SSH"

        ssh -o StrictHostKeyChecking=no "root@$NODE" \
            "cp \"$CONF_OLD\" \"$CONF_NEW\" && \
             sed -i \"s|/$ID_OLD/|/$ID_NEW/|g\" \"$CONF_NEW\" && \
             sed -i \"s|-$ID_OLD-|-$ID_NEW-|g\" \"$CONF_NEW\" && \
             sed -i \"s|:$ID_OLD/|:$ID_NEW/|g\" \"$CONF_NEW\" && \
             rm -f \"$CONF_OLD\"" \
            || { log "ERROR" "Echec SSH sur $NODE"; return 1; }

        log "SUCCESS" "Renommage distant OK sur $NODE"
        rename_storage_volumes "$ID_OLD" "$ID_NEW" "$NODE"
    fi

    log "SUCCESS" "Renommage terminé: $TYPE $ID_OLD → $ID_NEW"
    return 0
}

# ─────────────────────────────────────────
# 📊 RÉSUMÉ FINAL
# ─────────────────────────────────────────
show_summary() {
    local ID_OLD="$1"
    local ID_NEW="$2"
    local TYPE="$3"
    local NODE="$4"
    local BACKUP_FILE="$5"
    local type_label
    [[ "$TYPE" == "qemu" ]] && type_label="VM QEMU" || type_label="LXC Container"

    local dry_note=""
    [[ "$DRY_RUN" == "true" ]] && dry_note="\n⚠️  MODE DRY-RUN - Aucune modification réelle effectuée"

    dialog --title "Renommage Reussi!" \
        --msgbox "\
OPERATION REUSSIE${dry_note}

Type:      $type_label
Noeud:     $NODE
Ancien ID: $ID_OLD
Nouvel ID: $ID_NEW

Backup config: ${BACKUP_FILE:-N/A}
Log complet:   $LOGFILE

Prochaines etapes:
  1. Verifiez que la VM/LXC apparait bien
  2. Demarrez et testez la VM/LXC
  3. Supprimez le backup si tout est OK

Commande de verification:
  pvesh get /nodes/$NODE/$TYPE/$ID_NEW/config" \
        24 65

    log "SUCCESS" "=== RENOMMAGE COMPLET: $TYPE $ID_OLD → $ID_NEW sur $NODE ==="
}

# ─────────────────────────────────────────
# 🔄 WORKFLOW RENOMMAGE SIMPLE
# ─────────────────────────────────────────
single_rename_workflow() {
    local LOCAL_NODE
    LOCAL_NODE=$(hostname -s)
    local ID_OLD ID_NEW
    local FOUND_NODE FOUND_TYPE   # ← variables LOCALES : contournement du bug subshell

    # ── Saisie ancien VMID ──
    while true; do
        ID_OLD=$(dialog --stdout \
            --title "Etape 1/3 - Ancien VMID" \
            --inputbox "Entrez l'ID actuel de la VM/LXC:" \
            8 50) || return

        ID_OLD="${ID_OLD//[$'\t\r\n ']/}"

        if ! [[ "$ID_OLD" =~ ^[0-9]+$ ]]; then
            dialog --msgbox "VMID invalide: chiffres uniquement." 6 45
            continue
        fi

        if (( ID_OLD < 100 || ID_OLD > 1000000 )); then
            dialog --msgbox "VMID doit etre entre 100 et 1000000." 6 45
            continue
        fi

        # ⚠️  FIX BUG: capturer NODE_ASSIGNED et TYPE IMMÉDIATEMENT
        #     avant tout appel dialog (qui créerait un subshell)
        if find_vmid "$ID_OLD"; then
            FOUND_NODE="$NODE_ASSIGNED"   # capture immédiate
            FOUND_TYPE="$TYPE"            # capture immédiate
            log "INFO" "Capture: TYPE=$FOUND_TYPE NODE=$FOUND_NODE"

            if [[ -z "$FOUND_NODE" || -z "$FOUND_TYPE" ]]; then
                log "ERROR" "FOUND_NODE ou FOUND_TYPE vide après find_vmid !"
                dialog --msgbox "Erreur interne: impossible de déterminer le noeud.\nConsultez: $LOGFILE" 7 55
                continue
            fi
            break
        else
            dialog --msgbox "VMID $ID_OLD non trouvé sur aucun noeud." 6 50
        fi
    done

    local type_label
    [[ "$FOUND_TYPE" == "qemu" ]] && type_label="VM QEMU" || type_label="LXC Container"

    dialog --title "VM Trouvee" \
        --msgbox "VM trouvee:\n\n  Type:  $type_label\n  ID:    $ID_OLD\n  Noeud: $FOUND_NODE" \
        9 45

    # ── Vérification snapshots ──
    check_snapshots "$FOUND_NODE" "$ID_OLD" "$FOUND_TYPE" || return

    # ── Vérification VM arrêtée ──
    if ! check_vm_stopped "$FOUND_NODE" "$ID_OLD" "$FOUND_TYPE"; then
        dialog --title "VM en cours d'execution" \
            --yes-label "Arreter et continuer" \
            --no-label "Annuler" \
            --yesno "La VM $ID_OLD est en cours d'execution!\n\nVoulez-vous l'arreter maintenant?" \
            8 55

        if [[ $? -eq 0 ]]; then
            log "INFO" "Arrêt de $FOUND_TYPE $ID_OLD sur $FOUND_NODE"
            if [[ "$FOUND_NODE" == "$LOCAL_NODE" ]]; then
                pvesh create "/nodes/$FOUND_NODE/$FOUND_TYPE/$ID_OLD/status/stop" \
                    &>/dev/null || true
            else
                ssh "root@$FOUND_NODE" \
                    "pvesh create '/nodes/$FOUND_NODE/$FOUND_TYPE/$ID_OLD/status/stop'" \
                    &>/dev/null || true
            fi
            sleep 5
            log "SUCCESS" "$FOUND_TYPE $ID_OLD arrêtée"
        else
            return
        fi
    fi

    # ── Saisie nouvel VMID ──
    while true; do
        ID_NEW=$(dialog --stdout \
            --title "Etape 2/3 - Nouvel VMID" \
            --inputbox "Entrez le NOUVEL ID pour: $type_label $ID_OLD" \
            8 55) || return

        ID_NEW="${ID_NEW//[$'\t\r\n ']/}"

        if ! [[ "$ID_NEW" =~ ^[0-9]+$ ]]; then
            dialog --msgbox "Nouvel ID invalide: chiffres uniquement." 6 50
            continue
        fi

        if (( ID_NEW < 100 || ID_NEW > 1000000 )); then
            dialog --msgbox "VMID doit etre entre 100 et 1000000." 6 45
            continue
        fi

        if [[ "$ID_NEW" == "$ID_OLD" ]]; then
            dialog --msgbox "Le nouvel ID doit etre different de l'ancien!" 6 50
            continue
        fi

        if find_vmid "$ID_NEW" 2>/dev/null; then
            dialog --msgbox "Le VMID $ID_NEW est deja utilise!" 6 50
            continue
        fi

        break
    done

    # ── Confirmation (avec mention dry-run si actif) ──
    local dry_label=""
    [[ "$DRY_RUN" == "true" ]] && dry_label="\n  ⚠️  MODE SIMULATION (dry-run)\n"

    dialog --title "Etape 3/3 - Confirmation" \
        --yes-label "Confirmer" \
        --no-label "Annuler" \
        --yesno "\
Vous allez renommer:
${dry_label}
  Type:        $type_label
  Noeud:       $FOUND_NODE
  Ancien ID:   $ID_OLD
  Nouvel ID:   $ID_NEW

Cette action va:
  - Sauvegarder la config actuelle
  - Renommer le fichier de config
  - Mettre a jour les volumes (local/ZFS/Ceph)
  - Rollback automatique en cas d'erreur
  - Logger toutes les operations

Confirmez-vous ce renommage?" \
        22 55 || return

    # ── Exécution avec variables locales explicites ──
    log_separator
    log "INFO" "=== DEBUT RENOMMAGE: $FOUND_TYPE $ID_OLD → $ID_NEW sur $FOUND_NODE ==="
    log "INFO" "Vérification: TYPE='$FOUND_TYPE' | NODE='$FOUND_NODE'"

    local BACKUP_FILE=""
    if [[ "$DRY_RUN" == "false" ]]; then
        BACKUP_FILE=$(backup_config "$FOUND_NODE" "$ID_OLD" "$FOUND_TYPE")
    fi

    if rename_vmid "$ID_OLD" "$ID_NEW" "$FOUND_TYPE" "$FOUND_NODE"; then
        show_summary "$ID_OLD" "$ID_NEW" "$FOUND_TYPE" "$FOUND_NODE" "$BACKUP_FILE"
    else
        log "ERROR" "Renommage échoué - lancement du rollback"

        # ── Rollback automatique ──
        if [[ "$DRY_RUN" == "false" ]]; then
            dialog --title "Erreur - Rollback en cours" \
                --infobox "Le renommage a echoue!\nRollback automatique en cours..." \
                5 50
            sleep 1
            rollback_rename "$ID_OLD" "$ID_NEW" "$FOUND_TYPE" "$FOUND_NODE" "$BACKUP_FILE"
        fi

        dialog --title "Erreur" \
            --msgbox "Le renommage a echoue!\nRollback automatique effectué.\n\nConsultez: $LOGFILE" \
            8 60
        log "ERROR" "Renommage échoué + rollback: $FOUND_TYPE $ID_OLD → $ID_NEW"
    fi
}

# ─────────────────────────────────────────
# 📦 MODE BATCH
# ─────────────────────────────────────────
batch_rename() {
    log "INFO" "Mode batch activé"

    local BATCH_FILE
    BATCH_FILE=$(dialog --stdout \
        --title "Mode Batch CSV" \
        --inputbox "Chemin vers le fichier CSV:\n(Format: OLD_ID,NEW_ID par ligne)" \
        9 60) || return

    if [[ ! -f "$BATCH_FILE" ]]; then
        dialog --msgbox "Fichier non trouvé: $BATCH_FILE" 6 55
        return
    fi

    # Validation préalable du CSV
    local line_count=0
    local errors=""
    while IFS=',' read -r OLD_ID NEW_ID; do
        [[ "$OLD_ID" =~ ^#.*$ || -z "$OLD_ID" ]] && continue
        (( line_count++ )) || true
        OLD_ID="${OLD_ID// /}"
        NEW_ID="${NEW_ID// /}"
        if ! [[ "$OLD_ID" =~ ^[0-9]+$ && "$NEW_ID" =~ ^[0-9]+$ ]]; then
            errors+="Ligne invalide: $OLD_ID,$NEW_ID\n"
        fi
    done < "$BATCH_FILE"

    if [[ -n "$errors" ]]; then
        dialog --title "Erreurs CSV" \
            --msgbox "Erreurs détectées dans le fichier:\n\n$(echo -e "$errors")\nCorrigez avant de continuer." \
            15 60
        return
    fi

    dialog --title "Confirmation Batch" \
        --yes-label "Lancer" \
        --no-label "Annuler" \
        --yesno "$line_count opération(s) à effectuer.\n\nDry-run actif: $DRY_RUN\n\nConfirmer?" \
        8 50 || return

    local SUCCESS_COUNT=0
    local FAIL_COUNT=0
    local RESULTS=""
    local FOUND_NODE_B FOUND_TYPE_B   # variables locales batch

    while IFS=',' read -r OLD_ID NEW_ID; do
        [[ "$OLD_ID" =~ ^#.*$ || -z "$OLD_ID" ]] && continue

        OLD_ID="${OLD_ID// /}"
        NEW_ID="${NEW_ID// /}"

        log "INFO" "Batch: $OLD_ID → $NEW_ID"

        if find_vmid "$OLD_ID"; then
            FOUND_NODE_B="$NODE_ASSIGNED"
            FOUND_TYPE_B="$TYPE"

            if [[ -z "$FOUND_NODE_B" || -z "$FOUND_TYPE_B" ]]; then
                RESULTS+="FAIL $OLD_ID → $NEW_ID (noeud/type indéterminé)\n"
                (( FAIL_COUNT++ )) || true
                continue
            fi

            if ! check_vm_stopped "$FOUND_NODE_B" "$OLD_ID" "$FOUND_TYPE_B"; then
                RESULTS+="SKIP $OLD_ID → $NEW_ID (VM non arretee)\n"
                (( FAIL_COUNT++ )) || true
                continue
            fi

            local BFILE=""
            [[ "$DRY_RUN" == "false" ]] && \
                BFILE=$(backup_config "$FOUND_NODE_B" "$OLD_ID" "$FOUND_TYPE_B")

            if rename_vmid "$OLD_ID" "$NEW_ID" "$FOUND_TYPE_B" "$FOUND_NODE_B"; then
                RESULTS+="OK   $OLD_ID → $NEW_ID ($FOUND_TYPE_B sur $FOUND_NODE_B)\n"
                (( SUCCESS_COUNT++ )) || true
            else
                RESULTS+="FAIL $OLD_ID → $NEW_ID (erreur renommage)\n"
                [[ "$DRY_RUN" == "false" ]] && \
                    rollback_rename "$OLD_ID" "$NEW_ID" "$FOUND_TYPE_B" "$FOUND_NODE_B" "$BFILE"
                (( FAIL_COUNT++ )) || true
            fi
        else
            RESULTS+="FAIL $OLD_ID → $NEW_ID (non trouve)\n"
            (( FAIL_COUNT++ )) || true
        fi

    done < "$BATCH_FILE"

    dialog --title "Resultats Batch" \
        --msgbox "$(echo -e "Resultats:\n\n${RESULTS}\nSucces: $SUCCESS_COUNT | Echecs: $FAIL_COUNT\nLog: $LOGFILE")" \
        28 75
}

# ─────────────────────────────────────────
# 🔀 TOGGLE DRY-RUN
# ─────────────────────────────────────────
toggle_dry_run() {
    if [[ "$DRY_RUN" == "false" ]]; then
        DRY_RUN=true
        dialog --msgbox "Mode DRY-RUN ACTIVÉ\n\nAucune modification ne sera effectuée.\nToutes les actions seront simulées et loggées." 8 55
        log "INFO" "Mode dry-run activé"
    else
        DRY_RUN=false
        dialog --msgbox "Mode DRY-RUN DÉSACTIVÉ\n\nLes modifications seront appliquées réellement." 8 55
        log "INFO" "Mode dry-run désactivé"
    fi
}

# ─────────────────────────────────────────
# ℹ️ INFOS VMID
# ─────────────────────────────────────────
info_vmid() {
    local VMID
    VMID=$(dialog --stdout \
        --title "Infos VMID" \
        --inputbox "Entrez le VMID a inspecter:" \
        8 45) || return

    VMID="${VMID//[$'\t\r\n ']/}"

    if find_vmid "$VMID"; then
        local FN="$NODE_ASSIGNED"
        local FT="$TYPE"
        local config
        config=$(pvesh get "/nodes/$FN/$FT/$VMID/config" \
            --output-format=json 2>/dev/null | head -40 || echo "Erreur lecture config")

        # Snapshots
        local snaps
        snaps=$(pvesh get "/nodes/$FN/$FT/$VMID/snapshot" \
            --output-format=json 2>/dev/null \
            | grep -Po '"name"\s*:\s*"\K[^"]+' \
            | grep -v "^current$" | tr '\n' ' ' || echo "aucun")

        dialog --title "Infos VMID $VMID" \
            --msgbox "Type:      $FT\nNoeud:     $FN\nSnapshots: $snaps\n\nConfig (extrait):\n$config" \
            28 80
    else
        dialog --msgbox "VMID $VMID non trouvé." 6 40
    fi
}

# ─────────────────────────────────────────
# 📝 VOIR LES LOGS
# ─────────────────────────────────────────
view_logs() {
    if [[ -f "$LOGFILE" ]]; then
        dialog --title "Logs - $LOGFILE" \
            --textbox "$LOGFILE" \
            30 100
    else
        dialog --msgbox "Aucun log disponible." 6 40
    fi
}

# ─────────────────────────────────────────
# 🎮 MENU PRINCIPAL
# ─────────────────────────────────────────
main_menu() {
    while true; do
        local dry_status
        [[ "$DRY_RUN" == "true" ]] && dry_status="[DRY-RUN ON]" || dry_status=""

        local CHOICE
        CHOICE=$(dialog --stdout \
            --title "PROXMOX VMID UPDATER v2.2 $dry_status" \
            --menu "Noeuds: ${CLUSTER_NODES[*]}" \
            18 65 8 \
            "1" "Renommer un VMID (simple)" \
            "2" "Lister toutes les VMs/LXCs" \
            "3" "Mode Batch (CSV)" \
            "4" "Infos sur un VMID" \
            "5" "Voir les logs" \
            "6" "Toggle Dry-Run (simulation) [$DRY_RUN]" \
            "7" "Quitter") || { clear; exit 0; }

        case "$CHOICE" in
            1) single_rename_workflow ;;
            2) list_all_vms ;;
            3) batch_rename ;;
            4) info_vmid ;;
            5) view_logs ;;
            6) toggle_dry_run ;;
            7) clear; log "INFO" "Script terminé"; exit 0 ;;
        esac
    done
}

# ─────────────────────────────────────────
# 🚀 MAIN
# ─────────────────────────────────────────
main() {
    show_banner
    check_root
    check_dependencies
    show_warning
    detect_cluster_nodes
    check_quorum

    log_separator
    log "INFO" "=== PROXMOX VMID UPDATER v2.2 DEMARRÉ ==="
    log "INFO" "Noeuds: ${CLUSTER_NODES[*]}"
    log_separator

    main_menu

    clear
    echo -e "${GREEN}Script terminé. Log: $LOGFILE${NC}"
}

main "$@"
