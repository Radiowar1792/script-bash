#!/bin/bash
# ============================================================
# Script : rename_proxmox_node.sh
# Description : Renomme un nœud Proxmox de manière sécurisée
# Auteur : homelab
# Version : 1.0
# Usage : sudo bash rename_proxmox_node.sh
# ============================================================

set -euo pipefail

# ─────────────────────────────────────────
# COULEURS & HELPERS
# ─────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${RESET}    $1"; }
log_success() { echo -e "${GREEN}[OK]${RESET}      $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}    $1"; }
log_error()   { echo -e "${RED}[ERROR]${RESET}   $1"; }
log_step()    { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${RESET}"; }
log_fatal()   {
    echo -e "${RED}${BOLD}[FATAL]${RESET} $1"
    echo -e "${YELLOW}Rollback disponible : bash $0 --rollback${RESET}"
    exit 1
}

# ─────────────────────────────────────────
# CONSTANTES
# ─────────────────────────────────────────
BACKUP_DIR="/root/proxmox-rename-backup-$(date +%Y%m%d-%H%M%S)"
CONFIG_DB="/var/lib/pve-cluster/config.db"
RRDCACHED_BASE="/var/lib/rrdcached/db"
ROLLBACK_MARKER="/root/.proxmox_rename_rollback"

# ─────────────────────────────────────────
# PRÉ-REQUIS
# ─────────────────────────────────────────
check_prerequisites() {
    log_step "Vérification des prérequis"

    # Root
    if [[ $EUID -ne 0 ]]; then
        log_fatal "Ce script doit être exécuté en tant que root."
    fi
    log_success "Exécution en root"

    # Proxmox installé
    if ! command -v pvesh &>/dev/null; then
        log_fatal "pvesh introuvable. Ce script est réservé à un nœud Proxmox."
    fi
    log_success "Proxmox détecté"

    # sqlite3 disponible
    if ! command -v sqlite3 &>/dev/null; then
        log_warn "sqlite3 non trouvé. Installation..."
        apt-get install -y sqlite3 &>/dev/null || log_fatal "Impossible d'installer sqlite3."
    fi
    log_success "sqlite3 disponible"

    # Nœud en cluster ?
    NODE_COUNT=$(pvesh get /nodes --output-format json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "1")
    if [[ "$NODE_COUNT" -gt 1 ]]; then
        log_warn "Cluster multi-nœuds détecté ($NODE_COUNT nœuds)."
        log_warn "Ce script est prévu pour un nœud STANDALONE."
        log_warn "Pour un cluster, la procédure est plus complexe (voir doc officielle)."
        read -rp "$(echo -e ${YELLOW}Continuer quand même ? [oui/NON] : ${RESET})" CLUSTER_CONFIRM
        [[ "$CLUSTER_CONFIRM" == "oui" ]] || { log_info "Abandon."; exit 0; }
    else
        log_success "Nœud standalone confirmé"
    fi
}

# ─────────────────────────────────────────
# COLLECTE DES INFORMATIONS
# ─────────────────────────────────────────
collect_info() {
    log_step "Collecte des informations"

    OLD_HOSTNAME=$(hostname -s)
    OLD_FQDN=$(hostname -f 2>/dev/null || echo "$OLD_HOSTNAME")
    OLD_IP=$(grep -E "^\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" /etc/hosts | grep "$OLD_HOSTNAME" | awk '{print $1}' | head -1 || echo "")

    echo -e "\n${BOLD}Hostname actuel :${RESET} ${RED}$OLD_HOSTNAME${RESET}"
    echo -e "${BOLD}FQDN actuel     :${RESET} ${RED}$OLD_FQDN${RESET}"
    echo -e "${BOLD}IP détectée     :${RESET} ${CYAN}${OLD_IP:-"non trouvée dans /etc/hosts"}${RESET}\n"

    # Nouveau hostname
    while true; do
        read -rp "$(echo -e ${BOLD}Nouveau hostname court [ex: pve-01] : ${RESET})" NEW_HOSTNAME
        [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]] && break
        log_warn "Hostname invalide. Utilisez uniquement lettres, chiffres et tirets."
    done

    read -rp "$(echo -e ${BOLD}Domaine [ex: homelab.local, laisser vide si sans domaine] : ${RESET})" DOMAIN
    if [[ -n "$DOMAIN" ]]; then
        NEW_FQDN="${NEW_HOSTNAME}.${DOMAIN}"
    else
        NEW_FQDN="$NEW_HOSTNAME"
    fi

    # IP
    if [[ -z "$OLD_IP" ]]; then
        read -rp "$(echo -e ${BOLD}IP principale du nœud [ex: 192.168.1.10] : ${RESET})" NODE_IP
    else
        read -rp "$(echo -e ${BOLD}IP principale du nœud [défaut: ${OLD_IP}] : ${RESET})" NODE_IP
        NODE_IP="${NODE_IP:-$OLD_IP}"
    fi

    echo -e "\n${BOLD}─────────────────────────────────────────${RESET}"
    echo -e "  Ancien hostname : ${RED}$OLD_HOSTNAME${RESET}"
    echo -e "  Nouveau hostname: ${GREEN}$NEW_HOSTNAME${RESET}"
    echo -e "  Nouveau FQDN    : ${GREEN}$NEW_FQDN${RESET}"
    echo -e "  IP du nœud      : ${CYAN}$NODE_IP${RESET}"
    echo -e "${BOLD}─────────────────────────────────────────${RESET}\n"

    read -rp "$(echo -e ${YELLOW}${BOLD}Confirmer ces changements ? [oui/NON] : ${RESET})" CONFIRM
    [[ "$CONFIRM" == "oui" ]] || { log_info "Abandon par l'utilisateur."; exit 0; }
}

# ─────────────────────────────────────────
# BACKUP
# ─────────────────────────────────────────
do_backup() {
    log_step "Sauvegarde préventive → $BACKUP_DIR"

    mkdir -p "$BACKUP_DIR"

    # Fichiers système
    cp /etc/hostname        "$BACKUP_DIR/hostname.bak"
    cp /etc/hosts           "$BACKUP_DIR/hosts.bak"

    # Base de données pve-cluster
    if [[ -f "$CONFIG_DB" ]]; then
        cp "$CONFIG_DB" "$BACKUP_DIR/config.db.bak"
        log_success "config.db sauvegardée"
    else
        log_warn "config.db introuvable, sauvegarde ignorée"
    fi

    # Fichiers PVE
    [[ -f /etc/pve/.members ]] && cp /etc/pve/.members "$BACKUP_DIR/.members.bak"
    [[ -f /etc/pve/.vmlist  ]] && cp /etc/pve/.vmlist  "$BACKUP_DIR/.vmlist.bak"

    # Configs VM/LXC
    if [[ -d "/etc/pve/nodes/$OLD_HOSTNAME" ]]; then
        cp -r "/etc/pve/nodes/$OLD_HOSTNAME" "$BACKUP_DIR/nodes_backup"
        log_success "Configs VM/LXC sauvegardées"
    fi

    # RRD
    for subdir in "pve2-node" "pve2-storage"; do
        SRC_RRD="$RRDCACHED_BASE/$subdir/$OLD_HOSTNAME"
        [[ -d "$SRC_RRD" ]] && cp -r "$SRC_RRD" "$BACKUP_DIR/" && log_success "RRD $subdir sauvegardé"
    done

    # Marqueur rollback
    cat > "$ROLLBACK_MARKER" <<EOF
OLD_HOSTNAME=$OLD_HOSTNAME
NEW_HOSTNAME=$NEW_HOSTNAME
NEW_FQDN=$NEW_FQDN
NODE_IP=$NODE_IP
BACKUP_DIR=$BACKUP_DIR
EOF

    log_success "Backup complet dans $BACKUP_DIR"
}

# ─────────────────────────────────────────
# STOP SERVICES
# ─────────────────────────────────────────
stop_services() {
    log_step "Arrêt des services Proxmox"

    SERVICES=("pvedaemon" "pveproxy" "pvestatd" "pvebanner" "pve-cluster")
    for svc in "${SERVICES[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            systemctl stop "$svc" && log_success "$svc arrêté" || log_warn "Impossible d'arrêter $svc"
        else
            log_info "$svc déjà inactif"
        fi
    done
}

# ─────────────────────────────────────────
# RENAME
# ─────────────────────────────────────────
rename_hostname() {
    log_step "Modification du hostname système"

    # /etc/hostname
    echo "$NEW_FQDN" > /etc/hostname
    hostnamectl set-hostname "$NEW_FQDN"
    log_success "/etc/hostname → $NEW_FQDN"

    # /etc/hosts — supprimer anciennes lignes avec l'ancien hostname
    sed -i "/\b$OLD_HOSTNAME\b/d" /etc/hosts
    sed -i "/\b$OLD_FQDN\b/d"    /etc/hosts

    # Ajouter la nouvelle entrée
    if [[ "$NEW_FQDN" != "$NEW_HOSTNAME" ]]; then
        echo -e "$NODE_IP\t$NEW_FQDN $NEW_HOSTNAME" >> /etc/hosts
    else
        echo -e "$NODE_IP\t$NEW_HOSTNAME" >> /etc/hosts
    fi
    log_success "/etc/hosts mis à jour"
}

# ─────────────────────────────────────────
# MISE À JOUR FICHIERS PVE
# ─────────────────────────────────────────
update_pve_files() {
    log_step "Mise à jour des fichiers Proxmox"

    # .members et .vmlist (si accessibles — peuvent être gérés par pmxcfs)
    for f in /etc/pve/.members /etc/pve/.vmlist; do
        if [[ -f "$f" ]]; then
            sed -i "s/\b$OLD_HOSTNAME\b/$NEW_HOSTNAME/g" "$f" && log_success "$f mis à jour" || log_warn "Impossible de modifier $f (normal si pmxcfs actif)"
        fi
    done
}

# ─────────────────────────────────────────
# DÉPLACEMENT CONFIGS VM / LXC
# ─────────────────────────────────────────
move_vm_configs() {
    log_step "Migration des configs VM et LXC"

    OLD_NODE_DIR="/etc/pve/nodes/$OLD_HOSTNAME"
    NEW_NODE_DIR="/etc/pve/nodes/$NEW_HOSTNAME"

    if [[ ! -d "$OLD_NODE_DIR" ]]; then
        log_warn "Répertoire $OLD_NODE_DIR introuvable, migration ignorée"
        return
    fi

    # Attendre que pmxcfs crée le nouveau répertoire (après restart cluster)
    # On le crée manuellement si absent
    mkdir -p "$NEW_NODE_DIR/qemu-server"
    mkdir -p "$NEW_NODE_DIR/lxc"

    # Copie sécurisée
    QEMU_FILES=$(ls "$OLD_NODE_DIR/qemu-server/" 2>/dev/null | wc -l)
    LXC_FILES=$(ls "$OLD_NODE_DIR/lxc/" 2>/dev/null | wc -l)

    if [[ "$QEMU_FILES" -gt 0 ]]; then
        cp "$OLD_NODE_DIR/qemu-server/"* "$NEW_NODE_DIR/qemu-server/" && \
        log_success "$QEMU_FILES config(s) QEMU copiée(s)" || log_warn "Erreur copie QEMU"
    else
        log_info "Aucune VM QEMU trouvée"
    fi

    if [[ "$LXC_FILES" -gt 0 ]]; then
        cp "$OLD_NODE_DIR/lxc/"* "$NEW_NODE_DIR/lxc/" && \
        log_success "$LXC_FILES config(s) LXC copiée(s)" || log_warn "Erreur copie LXC"
    else
        log_info "Aucun conteneur LXC trouvé"
    fi
}

# ─────────────────────────────────────────
# SQLITE3 — VÉRIFICATION / NETTOYAGE
# ─────────────────────────────────────────
check_and_fix_sqlite() {
    log_step "Vérification de la base SQLite (config.db)"

    if [[ ! -f "$CONFIG_DB" ]]; then
        log_warn "config.db introuvable, étape ignorée"
        return
    fi

    # Vérifier intégrité
    INTEGRITY=$(sqlite3 "$CONFIG_DB" "PRAGMA integrity_check;" 2>/dev/null || echo "error")
    if [[ "$INTEGRITY" != "ok" ]]; then
        log_error "Intégrité config.db : $INTEGRITY"
        log_error "Restaurez depuis le backup : cp $BACKUP_DIR/config.db.bak $CONFIG_DB"
        log_fatal "Base de données corrompue, abandon."
    fi
    log_success "Intégrité config.db : OK"

    # Chercher les doublons sur le nouveau hostname
    DUPLICATES=$(sqlite3 "$CONFIG_DB" \
        "SELECT inode, parent, name FROM tree WHERE name = '$NEW_HOSTNAME';" 2>/dev/null || echo "")

    DUPE_COUNT=$(echo "$DUPLICATES" | grep -c '|' || true)

    if [[ "$DUPE_COUNT" -gt 1 ]]; then
        log_warn "Doublons détectés pour '$NEW_HOSTNAME' dans config.db :"
        echo "$DUPLICATES"

        # Garder l'inode le plus ancien (le plus petit), supprimer le récent
        MAX_INODE=$(sqlite3 "$CONFIG_DB" \
            "SELECT MAX(inode) FROM tree WHERE name = '$NEW_HOSTNAME';" 2>/dev/null)

        log_warn "Suppression du doublon (inode $MAX_INODE)..."
        sqlite3 "$CONFIG_DB" <<SQL
DELETE FROM tree WHERE inode = $MAX_INODE;
DELETE FROM tree WHERE parent = $MAX_INODE;
SQL
        log_success "Doublon supprimé (inode $MAX_INODE)"

    elif [[ "$DUPE_COUNT" -eq 1 ]]; then
        log_success "Aucun doublon dans config.db"
    else
        log_info "Aucune entrée pour '$NEW_HOSTNAME' dans config.db (sera créée au démarrage)"
    fi

    # Chercher et supprimer l'ancien hostname s'il reste
    OLD_ENTRIES=$(sqlite3 "$CONFIG_DB" \
        "SELECT inode, parent, name FROM tree WHERE name = '$OLD_HOSTNAME';" 2>/dev/null || echo "")

    if [[ -n "$OLD_ENTRIES" ]]; then
        log_warn "Ancien hostname encore présent dans config.db :"
        echo "$OLD_ENTRIES"
        OLD_INODE=$(sqlite3 "$CONFIG_DB" \
            "SELECT inode FROM tree WHERE name = '$OLD_HOSTNAME';" 2>/dev/null | head -1)
        read -rp "$(echo -e ${YELLOW}Supprimer l\'entrée '$OLD_HOSTNAME' \(inode $OLD_INODE\) ? [oui/NON] : ${RESET})" DEL_OLD
        if [[ "$DEL_OLD" == "oui" ]]; then
            sqlite3 "$CONFIG_DB" "DELETE FROM tree WHERE inode = $OLD_INODE;"
            sqlite3 "$CONFIG_DB" "DELETE FROM tree WHERE parent = $OLD_INODE;"
            log_success "Ancien hostname supprimé de config.db"
        fi
    else
        log_success "Aucune trace de l'ancien hostname dans config.db"
    fi

    # Nettoyage des orphelins
    log_info "Nettoyage des nœuds orphelins dans config.db..."
    sqlite3 "$CONFIG_DB" <<'SQL'
DELETE FROM tree
WHERE parent NOT IN (SELECT inode FROM tree)
  AND parent != 0;
SQL
    log_success "Orphelins nettoyés"
}

# ─────────────────────────────────────────
# RRD — DONNÉES DE PERFORMANCE
# ─────────────────────────────────────────
migrate_rrd_data() {
    log_step "Migration des données RRD (graphiques de performance)"

    for subdir in "pve2-node" "pve2-storage"; do
        SRC="$RRDCACHED_BASE/$subdir/$OLD_HOSTNAME"
        DST="$RRDCACHED_BASE/$subdir/$NEW_HOSTNAME"

        if [[ -d "$SRC" ]]; then
            mkdir -p "$DST"
            cp -r "$SRC/." "$DST/"
            rm -rf "$SRC"
            log_success "RRD $subdir migré : $OLD_HOSTNAME → $NEW_HOSTNAME"
        else
            log_info "RRD $subdir/$OLD_HOSTNAME non trouvé, ignoré"
        fi
    done
}

# ─────────────────────────────────────────
# NETTOYAGE ANCIEN RÉPERTOIRE NODE
# ─────────────────────────────────────────
cleanup_old_node() {
    log_step "Nettoyage de l'ancien répertoire node"

    OLD_NODE_DIR="/etc/pve/nodes/$OLD_HOSTNAME"
    if [[ -d "$OLD_NODE_DIR" ]]; then
        rm -rf "$OLD_NODE_DIR"
        log_success "Répertoire $OLD_NODE_DIR supprimé"
    else
        log_info "$OLD_NODE_DIR déjà absent"
    fi
}

# ─────────────────────────────────────────
# REDÉMARRAGE DES SERVICES
# ─────────────────────────────────────────
start_services() {
    log_step "Redémarrage des services Proxmox"

    # pve-cluster en premier
    systemctl start pve-cluster
    sleep 3

    SERVICES=("pvedaemon" "pveproxy" "pvestatd" "pvebanner")
    for svc in "${SERVICES[@]}"; do
        systemctl start "$svc" && log_success "$svc démarré" || log_warn "Erreur démarrage $svc"
        sleep 1
    done
}

# ─────────────────────────────────────────
# VÉRIFICATIONS FINALES
# ─────────────────────────────────────────
final_checks() {
    log_step "Vérifications finales"

    # hostname -s
    CURRENT_SHORT=$(hostname -s)
    if [[ "$CURRENT_SHORT" == "$NEW_HOSTNAME" ]]; then
        log_success "hostname -s = $CURRENT_SHORT ✓"
    else
        log_error "hostname -s = $CURRENT_SHORT (attendu: $NEW_HOSTNAME)"
    fi

    # hostname -f
    CURRENT_FQDN=$(hostname -f 2>/dev/null || echo "erreur")
    if [[ "$CURRENT_FQDN" == "$NEW_FQDN" ]]; then
        log_success "hostname -f = $CURRENT_FQDN ✓"
    else
        log_warn "hostname -f = $CURRENT_FQDN (attendu: $NEW_FQDN)"
        log_warn "Vérifiez /etc/hosts"
    fi

    # /etc/hosts ne contient plus l'ancien hostname
    if grep -q "\b$OLD_HOSTNAME\b" /etc/hosts; then
        log_warn "L'ancien hostname est encore présent dans /etc/hosts !"
    else
        log_success "/etc/hosts ne contient plus l'ancien hostname ✓"
    fi

    # Services actifs
    echo ""
    for svc in pve-cluster pvedaemon pveproxy; do
        if systemctl is-active --quiet "$svc"; then
            log_success "$svc : actif ✓"
        else
            log_error "$svc : INACTIF"
        fi
    done

    # pvesh /nodes
    echo ""
    log_info "Résultat de pvesh get /nodes :"
    sleep 2
    pvesh get /nodes 2>/dev/null || log_warn "pvesh non disponible (réessayez dans quelques secondes)"

    # Vérif répertoire node
    if [[ -d "/etc/pve/nodes/$NEW_HOSTNAME" ]]; then
        log_success "/etc/pve/nodes/$NEW_HOSTNAME existe ✓"
    else
        log_warn "/etc/pve/nodes/$NEW_HOSTNAME absent (sera créé par pmxcfs)"
    fi
}

# ─────────────────────────────────────────
# ROLLBACK
# ─────────────────────────────────────────
do_rollback() {
    log_step "ROLLBACK"

    if [[ ! -f "$ROLLBACK_MARKER" ]]; then
        log_fatal "Marqueur de rollback introuvable ($ROLLBACK_MARKER). Rollback impossible automatiquement."
    fi

    source "$ROLLBACK_MARKER"

    log_warn "Rollback : $NEW_HOSTNAME → $OLD_HOSTNAME"
    log_warn "Backup utilisé : $BACKUP_DIR"

    systemctl stop pvedaemon pveproxy pvestatd pvebanner pve-cluster 2>/dev/null || true

    # Restaurer fichiers système
    cp "$BACKUP_DIR/hostname.bak" /etc/hostname
    cp "$BACKUP_DIR/hosts.bak"    /etc/hosts
    hostnamectl set-hostname "$(cat /etc/hostname)"

    # Restaurer config.db
    if [[ -f "$BACKUP_DIR/config.db.bak" ]]; then
        cp "$BACKUP_DIR/config.db.bak" "$CONFIG_DB"
        log_success "config.db restaurée"
    fi

    # Restaurer .members / .vmlist
    [[ -f "$BACKUP_DIR/.members.bak" ]] && cp "$BACKUP_DIR/.members.bak" /etc/pve/.members
    [[ -f "$BACKUP_DIR/.vmlist.bak"  ]] && cp "$BACKUP_DIR/.vmlist.bak"  /etc/pve/.vmlist

    # Restaurer configs VM
    if [[ -d "$BACKUP_DIR/nodes_backup" ]]; then
        rm -rf "/etc/pve/nodes/$NEW_HOSTNAME" 2>/dev/null || true
        cp -r "$BACKUP_DIR/nodes_backup" "/etc/pve/nodes/$OLD_HOSTNAME"
        log_success "Configs VM restaurées"
    fi

    systemctl start pve-cluster
    sleep 3
    systemctl start pvedaemon pveproxy pvestatd pvebanner

    log_success "Rollback terminé. Hostname restauré : $OLD_HOSTNAME"
    rm -f "$ROLLBACK_MARKER"
}

# ─────────────────────────────────────────
# RÉSUMÉ FINAL
# ─────────────────────────────────────────
print_summary() {
    echo -e "\n${BOLD}${GREEN}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${GREEN}║         RENOMMAGE TERMINÉ AVEC SUCCÈS    ║${RESET}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${RESET}\n"
    echo -e "  ${BOLD}Ancien hostname :${RESET} ${RED}$OLD_HOSTNAME${RESET}"
    echo -e "  ${BOLD}Nouveau hostname:${RESET} ${GREEN}$NEW_HOSTNAME${RESET}"
    echo -e "  ${BOLD}Nouveau FQDN    :${RESET} ${GREEN}$NEW_FQDN${RESET}"
    echo -e "  ${BOLD}Backup dans     :${RESET} ${CYAN}$BACKUP_DIR${RESET}"
    echo -e "\n  ${YELLOW}⚠️  Pensez à vérifier les jobs de backup PBS${RESET}"
    echo -e "     qui référencent l'ancien hostname '${RED}$OLD_HOSTNAME${RESET}'\n"
    echo -e "  ${BOLD}Rollback possible :${RESET} bash $0 --rollback\n"
}

# ─────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────
main() {
    echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}   Proxmox Node Rename Script — v1.0           ${RESET}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${RESET}\n"

    # Mode rollback
    if [[ "${1:-}" == "--rollback" ]]; then
        do_rollback
        exit 0
    fi

    check_prerequisites
    collect_info
    do_backup
    stop_services
    rename_hostname
    update_pve_files
    check_and_fix_sqlite
    move_vm_configs
    migrate_rrd_data
    cleanup_old_node
    start_services
    final_checks
    print_summary
}

main "$@"
