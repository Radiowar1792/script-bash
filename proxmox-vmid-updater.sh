#!/bin/bash

set -euo pipefail

# ============================================================
# PROXMOX VMID UPDATER - Script Personnalisé
# Auteur: Radiowar1792
# Version: 2.0
# Description: Changement d'IDs LXC/VM sur noeuds Proxmox
#              avec vérifications de sécurité et logs
# ============================================================

# ─────────────────────────────────────────
# 📁 CONFIGURATION DES LOGS
# ─────────────────────────────────────────
LOGDIR="/var/log/proxmox-vmid-updater"
LOGFILE="$LOGDIR/rename-vmid-$(date '+%Y%m%d_%H%M%S').log"
mkdir -p "$LOGDIR"
touch "$LOGFILE"

# Couleurs pour affichage terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log() {
    local level="${1:-INFO}"
    shift
    local ts msg
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    msg="[$ts] [$level] $*"
    echo "$msg" >> "$LOGFILE"
    case "$level" in
        INFO)    echo -e "${CYAN}[INFO]${NC} $*" ;;
        SUCCESS) echo -e "${GREEN}[✔ OK]${NC} $*" ;;
        WARN)    echo -e "${YELLOW}[⚠ WARN]${NC} $*" ;;
        ERROR)   echo -e "${RED}[✖ ERROR]${NC} $*" >&2 ;;
        *)       echo "$msg" ;;
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
        echo -e "${RED}❌ Ce script doit être exécuté en tant que root!${NC}" >&2
        exit 1
    fi
    log "INFO" "Exécution en tant que root confirmée"
}

# ─────────────────────────────────────────
# 📦 VÉRIFICATION DES DÉPENDANCES
# ─────────────────────────────────────────
check_dependencies() {
    local NEEDS=()
    for cmd in dialog pvesh pvecm pvesm; do
        command -v "$cmd" > /dev/null 2>&1 || NEEDS+=("$cmd")
    done

    if (( ${#NEEDS[@]} > 0 )); then
        log "WARN" "Paquets manquants: ${NEEDS[*]}"
        echo -e "${YELLOW}Paquets manquants: ${NEEDS[*]}${NC}"
        read -rp "Installer via apt? [O/n] " ans
        ans=${ans:-O}
        if [[ "$ans" =~ ^[OoYy]$ ]]; then
            log "INFO" "Installation: ${NEEDS[*]}"
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
# 🖥️ BANNIÈRE D'ACCUEIL
# ─────────────────────────────────────────
show_banner() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║        🖥️  PROXMOX VMID UPDATER - v2.0              ║"
    echo "║     Changement d'IDs LXC/VM sur noeuds Proxmox      ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${YELLOW}📝 Log: $LOGFILE${NC}"
    echo ""
}

# ─────────────────────────────────────────
# ⚠️ AVERTISSEMENT DE SÉCURITÉ
# ─────────────────────────────────────────
show_warning() {
    dialog --title "⚠️  AVERTISSEMENT - UTILISATION À VOS RISQUES!" \
        --yes-label "Je comprends, Continuer" \
        --no-label "Annuler" \
        --yesno "\
╔══════════════════════════════════════════╗
║         ⚠️  ATTENTION IMPORTANTE        ║
╚══════════════════════════════════════════╝

Ce script modifie les VMIDs Proxmox (LXC et VM).

⚠️  RISQUES POTENTIELS:
  • Corruption de config si mal utilisé
  • Perte de données si VM en cours d'exécution
  • Problèmes de cluster si pas de quorum

✅ PRÉCAUTIONS PRISES:
  • Vérification que la VM/LXC est arrêtée
  • Sauvegarde automatique des configs
  • Vérification du quorum cluster
  • Logs détaillés de toutes les opérations

📋 AVANT DE CONTINUER:
  • Faites un snapshot/backup de vos VMs
  • Assurez-vous que les VMs sont arrêtées
  • Vérifiez que le cluster est en bonne santé

Continuez seulement si vous savez ce que vous faites!" \
        20 60 || { log "INFO" "Utilisateur a annulé au warning"; clear; exit 0; }
    
    log "INFO" "Utilisateur a accepté les avertissements"
}

# ─────────────────────────────────────────
# 🌐 DÉTECTION DES NOEUDS CLUSTER
# ─────────────────────────────────────────
detect_cluster_nodes() {
    CLUSTER_NODES=()
    
    if pvecm nodes &>/dev/null 2>&1; then
        mapfile -t CLUSTER_NODES < <(
            pvesh get /nodes --output-format=json 2>/dev/null \
            | grep -Po '"node"\s*:\s*"\K[^"]+'
        )
        log "INFO" "Mode Cluster détecté - Noeuds: ${CLUSTER_NODES[*]}"
    else
        THIS_NODE=$(hostname -s)
        CLUSTER_NODES=("$THIS_NODE")
        log "INFO" "Mode Standalone - Noeud local: $THIS_NODE"
    fi
    
    if (( ${#CLUSTER_NODES[@]} == 0 )); then
        log "ERROR" "Aucun noeud détecté!"
        exit 1
    fi
}

# ─────────────────────────────────────────
# 🔗 VÉRIFICATION DU QUORUM
# ─────────────────────────────────────────
check_quorum() {
    if (( ${#CLUSTER_NODES[@]} <= 1 )); then
        log "INFO" "Mode standalone - vérification quorum ignorée"
        return 0
    fi

    set +e
    RAW_STATUS=$(pvecm status 2>&1)
    RETVAL=$?
    set -e

    if (( RETVAL != 0 )); then
        QSTAT="No"
        log "WARN" "pvecm status échoué (exit $RETVAL), pas de quorum assumé"
    else
        QSTAT=$(awk -F: '/Quorate:/ {
            gsub(/^[ \t]+|[ \t]+$/, "", $2)
            print $2
        }' <<< "$RAW_STATUS")
        log "INFO" "Statut quorum cluster: $QSTAT"
    fi

    if [[ "$QSTAT" != "Yes" ]]; then
        dialog --title "❌ Pas de Quorum Cluster" \
            --msgbox "\
Le cluster n'a pas le quorum (Quorate: $QSTAT).

Veuillez restaurer le quorum avant de continuer.

Commandes utiles:
  pvecm status
  systemctl status corosync
  systemctl status pve-cluster" \
            12 60
        log "ERROR" "Cluster sans quorum ($QSTAT) - abandon"
        clear
        exit 1
    fi
    
    log "SUCCESS" "Quorum cluster OK"
}

# ─────────────────────────────────────────
# 📋 AFFICHER TOUTES LES VMs/LXCs
# ─────────────────────────────────────────
list_all_vms() {
    log_separator
    log "INFO" "Liste de toutes les VMs/LXCs disponibles:"
    
    local list_content=""
    
    for NODE in "${CLUSTER_NODES[@]}"; do
        log "INFO" "Scan du noeud: $NODE"
        
        # VMs QEMU
        local qemu_list
        qemu_list=$(pvesh get "/nodes/$NODE/qemu" --output-format=json 2>/dev/null \
            | grep -Po '"vmid"\s*:\s*\K[0-9]+' || echo "")
        
        # LXC Containers
        local lxc_list
        lxc_list=$(pvesh get "/nodes/$NODE/lxc" --output-format=json 2>/dev/null \
            | grep -Po '"vmid"\s*:\s*\K[0-9]+' || echo "")
        
        if [[ -n "$qemu_list" ]]; then
            for vmid in $qemu_list; do
                local name status
                name=$(pvesh get "/nodes/$NODE/qemu/$vmid/config" --output-format=json 2>/dev/null \
                    | grep -Po '"name"\s*:\s*"\K[^"]+' | head -1 || echo "N/A")
                status=$(pvesh get "/nodes/$NODE/qemu/$vmid/status/current" --output-format=json 2>/dev/null \
                    | grep -Po '"status"\s*:\s*"\K[^"]+' | head -1 || echo "unknown")
                list_content+="  [QEMU] ID: ${vmid} | Nom: ${name} | Status: ${status} | Noeud: ${NODE}\n"
            done
        fi
        
        if [[ -n "$lxc_list" ]]; then
            for vmid in $lxc_list; do
                local name status
                name=$(pvesh get "/nodes/$NODE/lxc/$vmid/config" --output-format=json 2>/dev/null \
                    | grep -Po '"hostname"\s*:\s*"\K[^"]+' | head -1 || echo "N/A")
                status=$(pvesh get "/nodes/$NODE/lxc/$vmid/status/current" --output-format=json 2>/dev/null \
                    | grep -Po '"status"\s*:\s*"\K[^"]+' | head -1 || echo "unknown")
                list_content+="  [LXC]  ID: ${vmid} | Nom: ${name} | Status: ${status} | Noeud: ${NODE}\n"
            done
        fi
    done
    
    if [[ -z "$list_content" ]]; then
        list_content="  Aucune VM ou LXC trouvée.\n"
    fi
    
    dialog --title "📋 VMs et LXCs disponibles" \
        --msgbox "$(echo -e "$list_content")" \
        30 80
}

# ─────────────────────────────────────────
# 🔍 RECHERCHER UN VMID SUR LES NOEUDS
# ─────────────────────────────────────────
find_vmid() {
    local ID_SEARCH="$1"
    NODE_ASSIGNED=""
    TYPE=""
    
    log "INFO" "Recherche du VMID $ID_SEARCH sur les noeuds: ${CLUSTER_NODES[*]}"
    
    # Recherche QEMU
    for N in "${CLUSTER_NODES[@]}"; do
        log "INFO" "Vérification QEMU VM $ID_SEARCH sur noeud $N"
        if pvesh get "/nodes/$N/qemu/$ID_SEARCH/config" &>/dev/null; then
            TYPE=qemu
            NODE_ASSIGNED=$N
            log "SUCCESS" "VM QEMU $ID_SEARCH trouvée sur noeud $N"
            return 0
        fi
    done
    
    # Recherche LXC
    for N in "${CLUSTER_NODES[@]}"; do
        log "INFO" "Vérification LXC CT $ID_SEARCH sur noeud $N"
        if pvesh get "/nodes/$N/lxc/$ID_SEARCH/config" &>/dev/null; then
            TYPE=lxc
            NODE_ASSIGNED=$N
            log "SUCCESS" "LXC CT $ID_SEARCH trouvée sur noeud $N"
            return 0
        fi
    done
    
    log "WARN" "VMID $ID_SEARCH non trouvé sur aucun noeud"
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
    
    log "INFO" "Status de $type $vmid sur $node: $status"
    
    if [[ "$status" != "stopped" ]]; then
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────
# 💾 SAUVEGARDER LA CONFIGURATION
# ─────────────────────────────────────────
backup_config() {
    local node="$1"
    local vmid="$2"
    local type="$3"
    local BACKUP_DIR="/var/lib/proxmox-vmid-backups"
    local BACKUP_FILE="$BACKUP_DIR/${type}_${vmid}_$(date '+%Y%m%d_%H%M%S').conf.bak"
    
    mkdir -p "$BACKUP_DIR"
    
    # Chemin config selon type
    local CONFIG_PATH
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
        log "WARN" "Config non trouvée: $CONFIG_PATH"
        echo ""
    fi
}

# ─────────────────────────────────────────
# 🔄 RENOMMER UN VMID - FONCTION PRINCIPALE
# ─────────────────────────────────────────
rename_vmid() {
    local ID_OLD="$1"
    local ID_NEW="$2"
    local TYPE="$3"
    local NODE="$4"
    local LOCAL_NODE
    LOCAL_NODE=$(hostname -s)
    
    log_separator
    log "INFO" "Début du renommage: $TYPE $ID_OLD → $ID_NEW sur noeud $NODE"
    
    # ── Chemins des configs ──
    local CONF_DIR_OLD CONF_DIR_NEW CONF_OLD CONF_NEW
    if [[ "$TYPE" == "qemu" ]]; then
        CONF_DIR_OLD="/etc/pve/nodes/$NODE/qemu-server"
        CONF_OLD="$CONF_DIR_OLD/$ID_OLD.conf"
        CONF_NEW="$CONF_DIR_OLD/$ID_NEW.conf"
    else
        CONF_DIR_OLD="/etc/pve/nodes/$NODE/lxc"
        CONF_OLD="$CONF_DIR_OLD/$ID_OLD.conf"
        CONF_NEW="$CONF_DIR_OLD/$ID_NEW.conf"
    fi
    
    # ── Vérification que la config existe ──
    if [[ ! -f "$CONF_OLD" ]]; then
        log "ERROR" "Fichier config introuvable: $CONF_OLD"
        dialog --title "❌ Erreur" \
            --msgbox "Config introuvable: $CONF_OLD\n\nAbandon de l'opération." \
            8 60
        return 1
    fi
    
    # ── Sauvegarde de la config ──
    local BACKUP_FILE
    BACKUP_FILE=$(backup_config "$NODE" "$ID_OLD" "$TYPE")
    
    # ── Renommage sur noeud LOCAL ──
    if [[ "$NODE" == "$LOCAL_NODE" ]]; then
        log "INFO" "Renommage LOCAL sur $NODE"
        
        # 1. Copier la config avec le nouvel ID
        cp "$CONF_OLD" "$CONF_NEW"
        log "SUCCESS" "Config copiée: $CONF_OLD → $CONF_NEW"
        
        # 2. Mettre à jour les références internes au vieil ID
        sed -i "s|/$ID_OLD/|/$ID_NEW/|g" "$CONF_NEW"
        sed -i "s|-$ID_OLD-|-$ID_NEW-|g" "$CONF_NEW"
        log "INFO" "Références internes mises à jour dans $CONF_NEW"
        
        # 3. Renommer les volumes de stockage
        rename_storage_volumes "$ID_OLD" "$ID_NEW" "$TYPE" "$NODE" "$CONF_NEW"
        
        # 4. Supprimer l'ancienne config
        rm -f "$CONF_OLD"
        log "SUCCESS" "Ancienne config supprimée: $CONF_OLD"
        
    else
        # ── Renommage sur noeud DISTANT via SSH ──
        log "INFO" "Renommage DISTANT sur $NODE via SSH"
        
        ssh -o StrictHostKeyChecking=no "root@$NODE" bash <<EOF
            set -euo pipefail
            cp "$CONF_OLD" "$CONF_NEW"
            sed -i "s|/$ID_OLD/|/$ID_NEW/|g" "$CONF_NEW"
            sed -i "s|-$ID_OLD-|-$ID_NEW-|g" "$CONF_NEW"
            rm -f "$CONF_OLD"
            echo "Renommage distant OK"
EOF
        log "SUCCESS" "Renommage distant OK sur $NODE"
        
        # Renommage des volumes distant
        rename_storage_volumes_remote "$ID_OLD" "$ID_NEW" "$TYPE" "$NODE"
    fi
    
    log "SUCCESS" "Renommage terminé: $TYPE $ID_OLD → $ID_NEW"
    log "INFO" "Backup conservé: $BACKUP_FILE"
    
    return 0
}

# ─────────────────────────────────────────
# 💽 RENOMMER LES VOLUMES DE STOCKAGE (LOCAL)
# ─────────────────────────────────────────
rename_storage_volumes() {
    local ID_OLD="$1"
    local ID_NEW="$2"
    local TYPE="$3"
    local NODE="$4"
    local CONF_FILE="$5"
    
    log "INFO" "Scan des volumes de stockage pour $TYPE $ID_OLD"
    
    # Récupérer les storages disponibles
    local STORAGES
    mapfile -t STORAGES < <(pvesm status --output-format=json 2>/dev/null \
        | grep -Po '"storage"\s*:\s*"\K[^"]+' || echo "")
    
    for STORAGE in "${STORAGES[@]}"; do
        local STORAGE_PATH
        STORAGE_PATH=$(pvesm path "$STORAGE:" 2>/dev/null | head -1 || echo "")
        
        [[ -z "$STORAGE_PATH" ]] && continue
        
        # Chercher les volumes avec l'ancien ID
        local OLD_PATTERNS=()
        
        if [[ "$TYPE" == "qemu" ]]; then
            # Patterns pour disques VM
            OLD_PATTERNS+=(
                "$STORAGE_PATH/images/$ID_OLD"
                "$STORAGE_PATH/vm-$ID_OLD-disk"
                "$STORAGE_PATH/base-$ID_OLD-disk"
            )
        else
            # Patterns pour LXC
            OLD_PATTERNS+=(
                "$STORAGE_PATH/images/$ID_OLD"
                "$STORAGE_PATH/subvol-$ID_OLD-disk"
                "$STORAGE_PATH/basevol-$ID_OLD-disk"
            )
        fi
        
        for PATTERN in "${OLD_PATTERNS[@]}"; do
            # Renommer les dossiers
            if [[ -d "$PATTERN" ]]; then
                local NEW_PATH="${PATTERN/$ID_OLD/$ID_NEW}"
                mv "$PATTERN" "$NEW_PATH"
                log "SUCCESS" "Dossier renommé: $PATTERN → $NEW_PATH"
            fi
            
            # Renommer les fichiers (images disques)
            for OLD_FILE in "${PATTERN}"* 2>/dev/null; do
                [[ -e "$OLD_FILE" ]] || continue
                local NEW_FILE="${OLD_FILE/$ID_OLD/$ID_NEW}"
                if [[ "$OLD_FILE" != "$NEW_FILE" ]]; then
                    mv "$OLD_FILE" "$NEW_FILE"
                    log "SUCCESS" "Fichier renommé: $OLD_FILE → $NEW_FILE"
                fi
            done
        done
    done
    
    log "INFO" "Renommage des volumes terminé"
}

# ─────────────────────────────────────────
# 💽 RENOMMER LES VOLUMES DISTANTS (SSH)
# ─────────────────────────────────────────
rename_storage_volumes_remote() {
    local ID_OLD="$1"
    local ID_NEW="$2"
    local TYPE="$3"
    local NODE="$4"
    
    log "INFO" "Renommage volumes distants sur $NODE"
    
    ssh -o StrictHostKeyChecking=no "root@$NODE" bash <<EOF
        set -euo pipefail
        
        # Recherche et renommage des volumes
        find /var/lib/vz /mnt -maxdepth 4 -name "*-${ID_OLD}-*" 2>/dev/null | while read -r f; do
            new_f="\${f//-${ID_OLD}-/-${ID_NEW}-}"
            if [[ "\$f" != "\$new_f" ]]; then
                mv "\$f" "\$new_f"
                echo "Renommé: \$f → \$new_f"
            fi
        done
        
        find /var/lib/vz /mnt -maxdepth 4 -name "*/${ID_OLD}" -type d 2>/dev/null | while read -r d; do
            new_d="\${d//${ID_OLD}/${ID_NEW}}"
            if [[ "\$d" != "\$new_d" ]]; then
                mv "\$d" "\$new_d"
                echo "Dossier renommé: \$d → \$new_d"
            fi
        done
        
        echo "Renommage volumes distants terminé"
EOF
    
    log "SUCCESS" "Volumes distants renommés sur $NODE"
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
    
    dialog --title "✅ Renommage Réussi!" \
        --msgbox "\
╔══════════════════════════════════════════╗
║           ✅ OPÉRATION RÉUSSIE           ║
╚══════════════════════════════════════════╝

Type:      $type_label
Noeud:     $NODE
Ancien ID: $ID_OLD
Nouvel ID: $ID_NEW

📁 Backup config: $BACKUP_FILE
📝 Log complet:   $LOGFILE

⚡ Prochaines étapes recommandées:
  1. Vérifiez que la VM/LXC apparaît bien
  2. Démarrez et testez la VM/LXC
  3. Supprimez le backup si tout est OK

Commande de vérification:
  pvesh get /nodes/$NODE/$TYPE/$ID_NEW/config" \
        22 65
    
    log "SUCCESS" "=== RENOMMAGE COMPLET: $TYPE $ID_OLD → $ID_NEW sur $NODE ==="
}

# ─────────────────────────────────────────
# 🔁 MODE BATCH - Renommages multiples
# ─────────────────────────────────────────
batch_rename() {
    log "INFO" "Mode batch activé"
    
    local BATCH_FILE
    BATCH_FILE=$(dialog --stdout \
        --title "Mode Batch" \
        --inputbox "Entrez le chemin vers votre fichier de renommage CSV:\n(Format: OLD_ID,NEW_ID par ligne)" \
        10 60) || return
    
    if [[ ! -f "$BATCH_FILE" ]]; then
        dialog --msgbox "Fichier non trouvé: $BATCH_FILE" 6 50
        return
    fi
    
    local SUCCESS_COUNT=0
    local FAIL_COUNT=0
    local RESULTS=""
    
    while IFS=',' read -r OLD_ID NEW_ID; do
        # Ignorer commentaires et lignes vides
        [[ "$OLD_ID" =~ ^#.*$ ]] && continue
        [[ -z "$OLD_ID" ]] && continue
        
        OLD_ID="${OLD_ID// /}"
        NEW_ID="${NEW_ID// /}"
        
        log "INFO" "Batch: traitement $OLD_ID → $NEW_ID"
        
        if find_vmid "$OLD_ID"; then
            if ! check_vm_stopped "$NODE_ASSIGNED" "$OLD_ID" "$TYPE"; then
                RESULTS+="❌ $OLD_ID → $NEW_ID (VM non arrêtée)\n"
                (( FAIL_COUNT++ ))
                continue
            fi
            
            if rename_vmid "$OLD_ID" "$NEW_ID" "$TYPE" "$NODE_ASSIGNED"; then
                RESULTS+="✅ $OLD_ID → $NEW_ID ($TYPE sur $NODE_ASSIGNED)\n"
                (( SUCCESS_COUNT++ ))
            else
                RESULTS+="❌ $OLD_ID → $NEW_ID (erreur renommage)\n"
                (( FAIL_COUNT++ ))
            fi
        else
            RESULTS+="❌ $OLD_ID → $NEW_ID (VMID non trouvé)\n"
            (( FAIL_COUNT++ ))
        fi
        
    done < "$BATCH_FILE"
    
    dialog --title "📊 Résultats Batch" \
        --msgbox "$(echo -e "Résultats:\n\n$RESULTS\n✅ Succès: $SUCCESS_COUNT\n❌ Échecs: $FAIL_COUNT")" \
        25 70
}

# ─────────────────────────────────────────
# 🎮 MENU PRINCIPAL
# ─────────────────────────────────────────
main_menu() {
    while true; do
        local CHOICE
        CHOICE=$(dialog --stdout \
            --title "🖥️ PROXMOX VMID UPDATER - Menu Principal" \
            --menu "Noeuds détectés: ${CLUSTER_NODES[*]}\nChoisissez une action:" \
            18 65 6 \
            "1" "🔄  Renommer un VMID (simple)" \
            "2" "📋  Lister toutes les VMs/LXCs" \
            "3" "📦  Mode Batch (CSV)" \
            "4" "📝  Voir les logs" \
            "5" "ℹ️   Infos sur un VMID" \
            "6" "🚪  Quitter") || { clear; exit 0; }
        
        case "$CHOICE" in
            1) single_rename_workflow ;;
            2) list_all_vms ;;
            3) batch_rename ;;
            4) view_logs ;;
            5) info_vmid ;;
            6) clear; log "INFO" "Script terminé par l'utilisateur"; exit 0 ;;
        esac
    done
}

# ─────────────────────────────────────────
# 🔄 WORKFLOW RENOMMAGE SIMPLE
# ─────────────────────────────────────────
single_rename_workflow() {
    local LOCAL_NODE
    LOCAL_NODE=$(hostname -s)
    
    # ── Saisie de l'ancien VMID ──
    while true; do
        ID_OLD=$(dialog --stdout \
            --title "Étape 1/3 - Ancien VMID" \
            --inputbox "Entrez l'ID actuel de la VM/LXC\n(100-1000000, ESC pour annuler):" \
            9 50) || return
        
        ID_OLD="${ID_OLD//[$'\t\r\n ']/}"
        
        if ! [[ "$ID_OLD" =~ ^[0-9]+$ ]]; then
            dialog --msgbox "❌ VMID invalide '$ID_OLD': chiffres uniquement." 6 50
            continue
        fi
        
        if (( ID_OLD < 100 || ID_OLD > 1000000 )); then
            dialog --msgbox "❌ VMID doit être entre 100 et 1000000." 6 50
            continue
        fi
        
        if find_vmid "$ID_OLD"; then
            break
        else
            dialog --msgbox "❌ VMID $ID_OLD non trouvé sur aucun noeud." 6 50
        fi
    done
    
    # ── Afficher infos VM trouvée ──
    local type_label
    [[ "$TYPE" == "qemu" ]] && type_label="VM QEMU" || type_label="LXC Container"
    
    dialog --title "✅ VM Trouvée" \
        --msgbox "VM trouvée:\n\n  Type:  $type_label\n  ID:    $ID_OLD\n  Noeud: $NODE_ASSIGNED" \
        10 45
    
    # ── Vérification que la VM est arrêtée ──
    if ! check_vm_stopped "$NODE_ASSIGNED" "$ID_OLD" "$TYPE"; then
        dialog --title "⚠️ VM en cours d'exécution" \
            --yes-label "Arrêter et continuer" \
            --no-label "Annuler" \
            --yesno "La VM $ID_OLD est actuellement en cours d'exécution!\n\nVoulez-vous l'arrêter maintenant?" \
            8 55 && {
            log "INFO" "Arrêt de $TYPE $ID_OLD sur $NODE_ASSIGNED"
            if [[ "$NODE_ASSIGNED" == "$LOCAL_NODE" ]]; then
                pvesh create "/nodes/$NODE_ASSIGNED/$TYPE/$ID_OLD/status/stop" &>/dev/null
            else
                ssh "root@$NODE_ASSIGNED" \
                    "pvesh create '/nodes/$NODE_ASSIGNED/$TYPE/$ID_OLD/status/stop'" &>/dev/null
            fi
            sleep 5
            log "SUCCESS" "$TYPE $ID_OLD arrêtée"
        } || return
    fi
    
    # ── Saisie du nouvel VMID ──
    while true; do
        ID_NEW=$(dialog --stdout \
            --title "Étape 2/3 - Nouvel VMID" \
            --inputbox "Entrez le NOUVEL ID pour le $type_label $ID_OLD\n(doit être libre et entre 100-1000000):" \
            9 55) || return
        
        ID_NEW="${ID_NEW//[$'\t\r\n ']/}"
        
        if ! [[ "$ID_NEW" =~ ^[0-9]+$ ]]; then
            dialog --msgbox "❌ Nouvel ID invalide: chiffres uniquement." 6 50
            continue
        fi
        
        if (( ID_NEW < 100 || ID_NEW > 1000000 )); then
            dialog --msgbox "❌ VMID doit être entre 100 et 1000000." 6 50
            continue
        fi
        
        if [[ "$ID_NEW" == "$ID_OLD" ]]; then
            dialog --msgbox "❌ Le nouvel ID doit être différent de l'ancien!" 6 50
            continue
        fi
        
        # Vérifier que le nouvel ID n'est pas déjà utilisé
        if find_vmid "$ID_NEW" 2>/dev/null; then
            dialog --msgbox "❌ Le VMID $ID_NEW est déjà utilisé sur $NODE_ASSIGNED!" 6 55
            continue
        fi
        
        break
    done
    
    # ── Confirmation finale ──
    dialog --title "⚠️ Étape 3/3 - Confirmation" \
        --yes-label "✅ Confirmer le renommage" \
        --no-label "❌ Annuler" \
        --yesno "\
Vous allez renommer:

  Type:        $type_label
  Noeud:       $NODE_ASSIGNED
  Ancien ID:   $ID_OLD
  Nouvel ID:   $ID_NEW

Cette action va:
  ✓ Sauvegarder la config actuelle
  ✓ Renommer le fichier de config
  ✓ Mettre à jour les chemins de stockage
  ✓ Logger toutes les opérations

Confirmez-vous ce renommage?" \
        20 55 || return
    
    # ── Exécution du renommage ──
    log "INFO" "=== DÉBUT RENOMMAGE: $TYPE $ID_OLD → $ID_NEW ==="
    
    local BACKUP_FILE
    BACKUP_FILE=$(backup_config "$NODE_ASSIGNED" "$ID_OLD" "$TYPE")
    
    if rename_vmid "$ID_OLD" "$ID_NEW" "$TYPE" "$NODE_ASSIGNED"; then
        show_summary "$ID_OLD" "$ID_NEW" "$TYPE" "$NODE_ASSIGNED" "$BACKUP_FILE"
    else
        dialog --title "❌ Erreur" \
            --msgbox "Le renommage a échoué!\n\nConsultez les logs: $LOGFILE" \
            8 55
        log "ERROR" "Renommage échoué: $TYPE $ID_OLD → $ID_NEW"
    fi
}

# ─────────────────────────────────────────
# 📝 VOIR LES LOGS
# ─────────────────────────────────────────
view_logs() {
    if [[ -f "$LOGFILE" ]]; then
        dialog --title "📝 Logs - $LOGFILE" \
            --textbox "$LOGFILE" \
            30 100
    else
        dialog --msgbox "Aucun log disponible." 6 40
    fi
}

# ─────────────────────────────────────────
# ℹ️ INFOS SUR UN VMID
# ─────────────────────────────────────────
info_vmid() {
    local VMID
    VMID=$(dialog --stdout \
        --title "ℹ️ Infos VMID" \
        --inputbox "Entrez le VMID à inspecter:" \
        8 45) || return
    
    VMID="${VMID//[$'\t\r\n ']/}"
    
    if find_vmid "$VMID"; then
        local CONFIG
        CONFIG=$(pvesh get "/nodes/$NODE_ASSIGNED/$TYPE/$VMID/config" \
            --output-format=json 2>/dev/null || echo "{}")
        
        dialog --title "ℹ️ Infos VMID $VMID" \
            --msgbox "Type: $TYPE\nNoeud: $NODE_ASSIGNED\n\nConfig:\n$CONFIG" \
            25 80
    else
        dialog --msgbox "VMID $VMID non trouvé." 6 40
    fi
}

# ─────────────────────────────────────────
# 🚀 POINT D'ENTRÉE PRINCIPAL
# ─────────────────────────────────────────
main() {
    show_banner
    check_root
    check_dependencies
    show_warning
    detect_cluster_nodes
    check_quorum
    
    log_separator
    log "INFO" "=== PROXMOX VMID UPDATER DÉMARRÉ ==="
    log "INFO" "Noeuds: ${CLUSTER_NODES[*]}"
    log "INFO" "Log: $LOGFILE"
    log_separator
    
    main_menu
    
    clear
    echo -e "${GREEN}✅ Script terminé. Log disponible: $LOGFILE${NC}"
}

# ─────────────────────────────────────────
# 🎯 LANCEMENT
# ─────────────────────────────────────────
main "$@"
