#!/bin/bash
# ============================================================
# Script : rename_lxc.sh
# Description : Renomme les LXC Proxmox (config PVE + interne)
# Auteur : Homelab
# Proxmox Version : PVE 8.4+
# Usage : bash rename_lxc.sh (depuis le nœud Proxmox en root)
# ============================================================

# --- Couleurs ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
# CONFIGURATION : Adapte ici si besoin
# ============================================================
declare -A LXC_IDS
LXC_IDS=(
  [101]="lxc-npm-01"
  [200]="lxc-wiki-01"
  [201]="lxc-vikunja-01"
)

DOMAIN="homelab.local"

# ============================================================
# FONCTIONS
# ============================================================

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERREUR]${NC} Ce script doit être lancé en root sur le nœud Proxmox."
    exit 1
  fi
}

check_pct() {
  if ! command -v pct &>/dev/null; then
    echo -e "${RED}[ERREUR]${NC} La commande 'pct' est introuvable. Es-tu bien sur un nœud Proxmox ?"
    exit 1
  fi
}

get_lxc_status() {
  pct status "$1" | awk '{print $2}'
}

rename_lxc() {
  local VMID=$1
  local NEW_HOSTNAME=$2
  local FQDN="${NEW_HOSTNAME}.${DOMAIN}"

  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  LXC ${VMID} → ${FQDN}${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # Vérifie que le LXC existe
  if ! pct config "$VMID" &>/dev/null; then
    echo -e "${RED}  [ERREUR]${NC} LXC ${VMID} introuvable. Passage au suivant."
    return 1
  fi

  # Récupère l'ancien hostname
  local OLD_HOSTNAME
  OLD_HOSTNAME=$(pct config "$VMID" | grep "^hostname:" | awk '{print $2}')
  echo -e "  ${YELLOW}Ancien hostname :${NC} ${OLD_HOSTNAME}"
  echo -e "  ${YELLOW}Nouveau hostname :${NC} ${FQDN}"

  # Confirmation
  echo ""
  read -r -p "  Confirmer le renommage ? [o/N] : " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[oO]$ ]]; then
    echo -e "  ${YELLOW}[SKIP]${NC} LXC ${VMID} ignoré."
    return 0
  fi

  # Vérifie le statut du LXC
  local STATUS
  STATUS=$(get_lxc_status "$VMID")
  echo ""
  echo -e "  ${CYAN}[INFO]${NC} Statut du LXC : ${STATUS}"

  local WAS_STOPPED=false
  if [[ "$STATUS" == "stopped" ]]; then
    echo -e "  ${YELLOW}[INFO]${NC} Le LXC est arrêté, démarrage temporaire..."
    pct start "$VMID"
    sleep 5
    WAS_STOPPED=true
  fi

  # ── ÉTAPE 1 : Changement hostname dans la config Proxmox ──
  echo -e "  ${CYAN}[1/3]${NC} Mise à jour config Proxmox..."
  if pct set "$VMID" --hostname "$FQDN"; then
    echo -e "  ${GREEN}[OK]${NC} Config Proxmox mise à jour."
  else
    echo -e "  ${RED}[ERREUR]${NC} Échec mise à jour config Proxmox."
    return 1
  fi

  # ── ÉTAPE 2 : /etc/hostname dans le LXC ──
  echo -e "  ${CYAN}[2/3]${NC} Mise à jour /etc/hostname dans le LXC..."
  if pct exec "$VMID" -- bash -c "echo '${NEW_HOSTNAME}' > /etc/hostname && hostname '${NEW_HOSTNAME}'"; then
    echo -e "  ${GREEN}[OK]${NC} /etc/hostname mis à jour → ${NEW_HOSTNAME}"
  else
    echo -e "  ${RED}[ERREUR]${NC} Échec mise à jour /etc/hostname."
  fi

  # ── ÉTAPE 3 : /etc/hosts dans le LXC ──
  echo -e "  ${CYAN}[3/3]${NC} Mise à jour /etc/hosts dans le LXC..."
  pct exec "$VMID" -- bash -c "
    # Sauvegarde
    cp /etc/hosts /etc/hosts.bak

    # Supprime l'ancienne entrée PVE
    sed -i '/# --- BEGIN PVE ---/,/# --- END PVE ---/d' /etc/hosts

    # Ajoute la nouvelle entrée PVE
    cat >> /etc/hosts << 'EOF'
# --- BEGIN PVE ---
127.0.1.1 ${NEW_HOSTNAME}.${DOMAIN} ${NEW_HOSTNAME}
# --- END PVE ---
EOF
  "
  echo -e "  ${GREEN}[OK]${NC} /etc/hosts mis à jour."

  # ── Redémarrage si le LXC était arrêté ──
  if [[ "$WAS_STOPPED" == true ]]; then
    echo -e "  ${YELLOW}[INFO]${NC} Le LXC était arrêté, on le ré-arrête..."
    pct stop "$VMID"
  else
    # Redémarrage pour appliquer le nouveau hostname proprement
    echo ""
    read -r -p "  Redémarrer le LXC ${VMID} pour appliquer ? [o/N] : " REBOOT
    if [[ "$REBOOT" =~ ^[oO]$ ]]; then
      echo -e "  ${CYAN}[INFO]${NC} Redémarrage du LXC ${VMID}..."
      pct reboot "$VMID"
      sleep 5
      echo -e "  ${GREEN}[OK]${NC} LXC ${VMID} redémarré."
    fi
  fi

  echo ""
  echo -e "  ${GREEN}[SUCCÈS]${NC} LXC ${VMID} renommé → ${FQDN}"
}

# ============================================================
# MAIN
# ============================================================

check_root
check_pct

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║         RENOMMAGE LXC - PROXMOX HOMELAB             ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  LXC ciblés :"
echo -e "  ${YELLOW}101${NC} → lxc-npm-01.${DOMAIN}       (Nginx Proxy Manager)"
echo -e "  ${YELLOW}200${NC} → lxc-wiki-01.${DOMAIN}      (Docmost)"
echo -e "  ${YELLOW}201${NC} → lxc-vikunja-01.${DOMAIN}   (Vikunja)"
echo ""
read -r -p "Lancer le script ? [o/N] : " START
if [[ ! "$START" =~ ^[oO]$ ]]; then
  echo -e "${YELLOW}Annulé.${NC}"
  exit 0
fi

# Boucle sur chaque LXC
for VMID in "${!LXC_IDS[@]}"; do
  rename_lxc "$VMID" "${LXC_IDS[$VMID]}"
done

echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Terminé ! Tous les LXC ont été traités.${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${NC}"
echo ""

# Résumé final
echo -e "${BOLD}Résumé :${NC}"
for VMID in "${!LXC_IDS[@]}"; do
  CURRENT=$(pct config "$VMID" 2>/dev/null | grep "^hostname:" | awk '{print $2}')
  echo -e "  LXC ${YELLOW}${VMID}${NC} → hostname actuel : ${GREEN}${CURRENT}${NC}"
done
echo ""
