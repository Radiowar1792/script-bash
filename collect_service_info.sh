#!/bin/bash
# ============================================================
# collect_service_info.sh
# Collecte automatique d'informations pour la Fiche Service
# À exécuter DANS le LXC ou la VM hébergeant le service
# Usage : bash collect_service_info.sh [nom-du-service]
# Ex    : bash collect_service_info.sh nginx
# ============================================================

# ── Couleurs ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Variables ───────────────────────────────────────────────
SERVICE_NAME="${1:-}"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
OUTPUT_FILE="/root/fiche_service_${SERVICE_NAME:-unknown}_${TIMESTAMP}.md"
SEPARATOR="────────────────────────────────────────────────────────"

# ── Fonctions utilitaires ───────────────────────────────────
print_section() {
    echo -e "\n${CYAN}${BOLD}>>> $1${NC}"
}

print_ok() {
    echo -e "  ${GREEN}✔${NC} $1"
}

print_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

cmd_or_na() {
    # Exécute une commande, retourne "N/A" si elle échoue
    local result
    result=$(eval "$1" 2>/dev/null)
    if [[ -z "$result" ]]; then
        echo "N/A"
    else
        echo "$result"
    fi
}

# ── Vérification root ───────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERREUR]${NC} Ce script doit être exécuté en root."
    echo "  → sudo bash $0 $*"
    exit 1
fi

# ── Demande du nom de service si non fourni ─────────────────
if [[ -z "$SERVICE_NAME" ]]; then
    echo -e "${YELLOW}Nom du service systemd à analyser (ex: nginx, docker, jellyfin) :${NC}"
    read -r SERVICE_NAME
fi

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║      COLLECTE FICHE SERVICE — HOMELAB DOCS          ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
echo -e "  Service ciblé : ${YELLOW}${SERVICE_NAME}${NC}"
echo -e "  Output        : ${YELLOW}${OUTPUT_FILE}${NC}"
echo ""

# ════════════════════════════════════════════════════════════
# COLLECTE DES DONNÉES
# ════════════════════════════════════════════════════════════

# ── 1. Identité système ─────────────────────────────────────
print_section "Identité système"

HOSTNAME=$(hostname)
OS_NAME=$(grep '^PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
OS_ID=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2)
OS_VERSION=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
KERNEL=$(uname -r)
ARCH=$(uname -m)
UPTIME_HUMAN=$(uptime -p 2>/dev/null || uptime)
TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "N/A")
LOCALE=$(locale | grep LANG= | cut -d= -f2 | head -1)
INSTALL_DATE=$(cmd_or_na "stat /lost+found 2>/dev/null | grep 'Birth' | awk '{print \$2}' || ls -lct /etc | tail -1 | awk '{print \$6, \$7}'")

print_ok "Hostname     : $HOSTNAME"
print_ok "OS           : $OS_NAME"
print_ok "Kernel       : $KERNEL"
print_ok "Architecture : $ARCH"
print_ok "Uptime       : $UPTIME_HUMAN"
print_ok "Timezone     : $TIMEZONE"

# ── 2. Ressources CPU ───────────────────────────────────────
print_section "CPU"

CPU_MODEL=$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)
CPU_CORES=$(nproc --all 2>/dev/null)
CPU_CORES_ONLINE=$(nproc 2>/dev/null)
CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)

print_ok "Modèle  : $CPU_MODEL"
print_ok "vCPUs   : $CPU_CORES_ONLINE / $CPU_CORES alloués"
print_ok "Load    : $CPU_LOAD"

# ── 3. Mémoire RAM ──────────────────────────────────────────
print_section "Mémoire RAM"

RAM_TOTAL=$(free -h | awk '/^Mem:/{print $2}')
RAM_USED=$(free -h | awk '/^Mem:/{print $3}')
RAM_FREE=$(free -h | awk '/^Mem:/{print $4}')
RAM_PERCENT=$(free | awk '/^Mem:/{printf "%.1f%%", $3/$2*100}')
SWAP_TOTAL=$(free -h | awk '/^Swap:/{print $2}')
SWAP_USED=$(free -h | awk '/^Swap:/{print $3}')

print_ok "RAM Total  : $RAM_TOTAL"
print_ok "RAM Utilisé: $RAM_USED ($RAM_PERCENT)"
print_ok "RAM Libre  : $RAM_FREE"
print_ok "Swap Total : $SWAP_TOTAL | Utilisé : $SWAP_USED"

# ── 4. Stockage ─────────────────────────────────────────────
print_section "Stockage"

DISK_INFO=$(df -h --output=source,fstype,size,used,avail,pcent,target 2>/dev/null | grep -v tmpfs | grep -v devtmpfs | grep -v udev)

print_ok "Partitions montées :"
echo "$DISK_INFO" | while read -r line; do
    echo "      $line"
done

# ── 5. Réseau ───────────────────────────────────────────────
print_section "Réseau"

# Interfaces et IPs
NET_INTERFACES=$(ip -o addr show 2>/dev/null | grep -v '^[0-9]*: lo' | awk '{print $2, $3, $4}')
GATEWAY=$(ip route show default 2>/dev/null | awk '/default/{print $3}' | head -1)
DNS_SERVERS=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd ', ')
HOSTNAME_FQDN=$(hostname -f 2>/dev/null || echo "N/A")

print_ok "Interfaces :"
echo "$NET_INTERFACES" | while read -r line; do
    echo "      $line"
done
print_ok "Gateway   : ${GATEWAY:-N/A}"
print_ok "DNS       : ${DNS_SERVERS:-N/A}"
print_ok "FQDN      : $HOSTNAME_FQDN"

# Ports en écoute
print_ok "Ports en écoute :"
if command -v ss &>/dev/null; then
    PORTS=$(ss -tlnp 2>/dev/null | grep LISTEN | awk '{print $4, $6}' | sed 's/users:((//' | sed 's/))//')
elif command -v netstat &>/dev/null; then
    PORTS=$(netstat -tlnp 2>/dev/null | grep LISTEN | awk '{print $4, $7}')
else
    PORTS="ss/netstat non disponible — installer iproute2"
fi
echo "$PORTS" | while read -r line; do
    echo "      $line"
done

# ── 6. Analyse du service systemd ───────────────────────────
print_section "Service systemd : $SERVICE_NAME"

if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}"; then
    SVC_STATUS=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
    SVC_ENABLED=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null)
    SVC_SINCE=$(systemctl show "$SERVICE_NAME" --property=ActiveEnterTimestamp --value 2>/dev/null)
    SVC_PID=$(systemctl show "$SERVICE_NAME" --property=MainPID --value 2>/dev/null)
    SVC_MEM=$(systemctl show "$SERVICE_NAME" --property=MemoryCurrent --value 2>/dev/null)
    SVC_RESTART=$(systemctl show "$SERVICE_NAME" --property=NRestarts --value 2>/dev/null)
    SVC_EXEC=$(systemctl show "$SERVICE_NAME" --property=ExecStart --value 2>/dev/null | head -c 200)

    print_ok "Statut    : $SVC_STATUS"
    print_ok "Enabled   : $SVC_ENABLED"
    print_ok "Depuis    : $SVC_SINCE"
    print_ok "PID       : $SVC_PID"
    print_ok "Mémoire   : ${SVC_MEM:-N/A} bytes"
    print_ok "Restarts  : $SVC_RESTART"
    print_ok "ExecStart : $SVC_EXEC"
else
    print_warn "Service '$SERVICE_NAME' non trouvé dans systemd."
    print_warn "Services actifs disponibles :"
    systemctl list-units --type=service --state=running 2>/dev/null | grep -v "^$" | head -20 | while read -r line; do
        echo "      $line"
    done
fi

# ── 7. Docker (si applicable) ───────────────────────────────
print_section "Docker (si applicable)"

if command -v docker &>/dev/null; then
    DOCKER_VERSION=$(docker --version 2>/dev/null)
    print_ok "Docker version : $DOCKER_VERSION"
    print_ok "Containers actifs :"
    docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | while read -r line; do
        echo "      $line"
    done
    print_ok "Images disponibles :"
    docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}" 2>/dev/null | head -15 | while read -r line; do
        echo "      $line"
    done
    print_ok "Volumes Docker :"
    docker volume ls 2>/dev/null | while read -r line; do
        echo "      $line"
    done
    print_ok "Networks Docker :"
    docker network ls 2>/dev/null | while read -r line; do
        echo "      $line"
    done
else
    print_warn "Docker non installé sur ce système"
fi

# ── 8. Versions des logiciels courants ──────────────────────
print_section "Versions logiciels détectés"

declare -A SOFTWARES=(
    ["nginx"]="nginx -v"
    ["apache2"]="apache2 -v"
    ["php"]="php -v"
    ["python3"]="python3 --version"
    ["node"]="node --version"
    ["npm"]="npm --version"
    ["git"]="git --version"
    ["curl"]="curl --version"
    ["wget"]="wget --version"
    ["openssl"]="openssl version"
    ["certbot"]="certbot --version"
    ["fail2ban-client"]="fail2ban-client --version"
    ["ufw"]="ufw version"
)

for soft in "${!SOFTWARES[@]}"; do
    if command -v "$soft" &>/dev/null; then
        version=$(eval "${SOFTWARES[$soft]}" 2>/dev/null | head -1)
        print_ok "$soft : $version"
    fi
done

# ── 9. Certificats SSL ──────────────────────────────────────
print_section "Certificats SSL (Let's Encrypt)"

if [[ -d /etc/letsencrypt/live ]]; then
    print_ok "Certificats trouvés :"
    for cert_dir in /etc/letsencrypt/live/*/; do
        domain=$(basename "$cert_dir")
        if [[ -f "$cert_dir/cert.pem" ]]; then
            expiry=$(openssl x509 -enddate -noout -in "$cert_dir/cert.pem" 2>/dev/null | cut -d= -f2)
            issuer=$(openssl x509 -issuer -noout -in "$cert_dir/cert.pem" 2>/dev/null | cut -d= -f2)
            echo "      📜 $domain → Expire : $expiry | Émis par : $issuer"
        fi
    done
else
    print_warn "Aucun certificat Let's Encrypt trouvé dans /etc/letsencrypt/live"
fi

# Certificats auto-signés dans /etc/ssl
if ls /etc/ssl/certs/*.pem &>/dev/null; then
    print_ok "Certificats dans /etc/ssl/certs/ :"
    for cert in /etc/ssl/certs/*.pem; do
        expiry=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
        [[ -n "$expiry" ]] && echo "      📜 $(basename $cert) → Expire : $expiry"
    done
fi

# ── 10. Sécurité ────────────────────────────────────────────
print_section "Sécurité"

# SSH
SSH_ROOT=$(grep '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
SSH_PWAUTH=$(grep '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
SSH_PORT=$(grep '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')

print_ok "SSH Root Login    : ${SSH_ROOT:-non défini (default: yes)}"
print_ok "SSH Password Auth : ${SSH_PWAUTH:-non défini (default: yes)}"
print_ok "SSH Port          : ${SSH_PORT:-22 (défaut)}"

# Fail2ban
if command -v fail2ban-client &>/dev/null; then
    F2B_STATUS=$(fail2ban-client status 2>/dev/null | head -5)
    print_ok "Fail2ban :"
    echo "$F2B_STATUS" | while read -r line; do echo "      $line"; done
else
    print_warn "Fail2ban non installé"
fi

# UFW
if command -v ufw &>/dev/null; then
    UFW_STATUS=$(ufw status 2>/dev/null | head -3)
    print_ok "UFW :"
    echo "$UFW_STATUS" | while read -r line; do echo "      $line"; done
else
    print_warn "UFW non installé"
fi

# Connexions actives suspectes
print_ok "Connexions ESTABLISHED actives (top 10) :"
ss -tnp 2>/dev/null | grep ESTAB | head -10 | while read -r line; do
    echo "      $line"
done

# ── 11. Logs récents du service ─────────────────────────────
print_section "Logs récents du service : $SERVICE_NAME (30 dernières lignes)"

if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}"; then
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager 2>/dev/null | while read -r line; do
        echo "      $line"
    done
else
    print_warn "Service '$SERVICE_NAME' introuvable — logs ignorés"
fi

# ── 12. Crontabs ────────────────────────────────────────────
print_section "Tâches planifiées (crontab)"

ROOT_CRON=$(crontab -l 2>/dev/null)
if [[ -n "$ROOT_CRON" ]]; then
    print_ok "Crontab root :"
    echo "$ROOT_CRON" | while read -r line; do echo "      $line"; done
else
    print_warn "Crontab root vide ou inexistant"
fi

print_ok "Crons système (/etc/cron.d/) :"
ls /etc/cron.d/ 2>/dev/null | while read -r line; do echo "      $line"; done

# ── 13. Packages installés notables ─────────────────────────
print_section "Derniers packages installés (20 derniers)"

if command -v dpkg &>/dev/null; then
    grep " install " /var/log/dpkg.log 2>/dev/null | tail -20 | while read -r line; do
        echo "      $line"
    done
fi

# ════════════════════════════════════════════════════════════
# GÉNÉRATION DU FICHIER MARKDOWN
# ════════════════════════════════════════════════════════════

print_section "Génération du fichier Markdown → $OUTPUT_FILE"

cat > "$OUTPUT_FILE" << MARKDOWN
# 🏷️ FICHE SERVICE — ${SERVICE_NAME^^}

> **Généré automatiquement le :** $(date '+%d/%m/%Y à %H:%M:%S')
> **Script :** collect_service_info.sh
> **Hôte :** $HOSTNAME
> **Statut du service :** 🔵 À compléter manuellement

---

## 1. 📋 IDENTITÉ DU SERVICE

| Champ | Valeur |
|-------|--------|
| **Nom du service** | $SERVICE_NAME |
| **Rôle / Fonction** | _À compléter_ |
| **Catégorie** | _À compléter_ |
| **Logiciel / Stack** | _À compléter_ |
| **Version actuelle** | _À compléter_ |
| **Site officiel** | _À compléter_ |
| **Licence** | _À compléter_ |
| **Date de déploiement initial** | _À compléter_ |

---

## 2. 🖥️ HÉBERGEMENT ET RESSOURCES

| Champ | Valeur |
|-------|--------|
| **Nœud Proxmox** | _À compléter_ |
| **Type de conteneur** | _LXC / VM_ |
| **ID Proxmox** | _À compléter_ |
| **Nom de la machine** | $HOSTNAME |
| **OS / Template** | $OS_NAME |
| **Kernel** | $KERNEL |
| **Architecture** | $ARCH |
| **vCPUs alloués** | $CPU_CORES_ONLINE |
| **RAM totale** | $RAM_TOTAL |
| **RAM utilisée** | $RAM_USED ($RAM_PERCENT) |
| **Swap** | $SWAP_TOTAL (utilisé : $SWAP_USED) |
| **Timezone** | $TIMEZONE |
| **Uptime** | $UPTIME_HUMAN |

---

## 3. 💾 STOCKAGE

\`\`\`
$(df -h --output=source,fstype,size,used,avail,pcent,target 2>/dev/null | grep -v tmpfs | grep -v devtmpfs)
\`\`\`

---

## 4. 🌐 RÉSEAU ET ACCÈS

| Interface | Type | Adresse | Passerelle | DNS |
|-----------|------|---------|-----------|-----|
$(ip -o addr show 2>/dev/null | grep -v lo | awk '{print "| " $2 " | " $3 " | " $4 " | '"$GATEWAY"' | '"$DNS_SERVERS"' |"}')

**Ports en écoute :**
\`\`\`
$(ss -tlnp 2>/dev/null | grep LISTEN)
\`\`\`

---

## 5. ⚙️ SERVICE SYSTEMD

| Champ | Valeur |
|-------|--------|
| **Nom systemd** | $SERVICE_NAME |
| **Statut** | $(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "N/A") |
| **Enabled** | $(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo "N/A") |
| **Actif depuis** | $(systemctl show "$SERVICE_NAME" --property=ActiveEnterTimestamp --value 2>/dev/null || echo "N/A") |
| **PID** | $(systemctl show "$SERVICE_NAME" --property=MainPID --value 2>/dev/null || echo "N/A") |
| **Nombre de restarts** | $(systemctl show "$SERVICE_NAME" --property=NRestarts --value 2>/dev/null || echo "N/A") |

---

## 6. 🐳 DOCKER

$(if command -v docker &>/dev/null; then
    echo "**Version :** $(docker --version 2>/dev/null)"
    echo ""
    echo "**Containers actifs :**"
    echo "\`\`\`"
    docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
    echo "\`\`\`"
    echo ""
    echo "**Volumes :**"
    echo "\`\`\`"
    docker volume ls 2>/dev/null
    echo "\`\`\`"
else
    echo "_Docker non installé sur ce système_"
fi)

---

## 7. 🔐 SÉCURITÉ SSH

| Champ | Valeur |
|-------|--------|
| **PermitRootLogin** | ${SSH_ROOT:-non défini} |
| **PasswordAuthentication** | ${SSH_PWAUTH:-non défini} |
| **Port SSH** | ${SSH_PORT:-22} |
| **Fail2ban** | $(command -v fail2ban-client &>/dev/null && echo "Installé" || echo "Non installé") |
| **UFW** | $(command -v ufw &>/dev/null && ufw status 2>/dev/null | head -1 || echo "Non installé") |

---

## 8. 📜 CERTIFICATS SSL

$(if [[ -d /etc/letsencrypt/live ]]; then
    for cert_dir in /etc/letsencrypt/live/*/; do
        domain=$(basename "$cert_dir")
        if [[ -f "$cert_dir/cert.pem" ]]; then
            expiry=$(openssl x509 -enddate -noout -in "$cert_dir/cert.pem" 2>/dev/null | cut -d= -f2)
            echo "- **$domain** → Expire : $expiry"
        fi
    done
else
    echo "_Aucun certificat Let's Encrypt trouvé_"
fi)

---

## 9. 📋 LOGS RÉCENTS (30 lignes)

\`\`\`
$(journalctl -u "$SERVICE_NAME" -n 30 --no-pager 2>/dev/null || echo "Logs non disponibles")
\`\`\`

---

## 10. 🔄 TÂCHES PLANIFIÉES

\`\`\`
$(crontab -l 2>/dev/null || echo "Crontab vide")
\`\`\`

---

## 11. 📝 NOTES ET CHANGELOG

| Date | Type | Description | Auteur |
|------|------|-------------|--------|
| $(date '+%d/%m/%Y') | Création | Fiche générée automatiquement | Script |

---

## 12. 🔗 LIENS

| Type | Lien |
|------|------|
| 📁 Projet Vikunja | _À compléter_ |
| 📄 Fiche équipement hôte | _À compléter_ |
| 📄 Documentation officielle | _À compléter_ |
| 📊 Dashboard Grafana | _À compléter_ |

---
*Généré par collect_service_info.sh — $(date '+%d/%m/%Y %H:%M:%S')*
*Compléter les champs marqués "À compléter" avant import dans Docmost*
MARKDOWN

echo ""
echo -e "${GREEN}${BOLD}✅ Collecte terminée !${NC}"
echo -e "   Fichier généré : ${YELLOW}$OUTPUT_FILE${NC}"
echo ""
echo -e "${CYAN}Prochaines étapes :${NC}"
echo -e "  1. Ouvrir le fichier : ${BOLD}cat $OUTPUT_FILE${NC}"
echo -e "  2. Compléter les champs 'À compléter'"
echo -e "  3. Importer dans Docmost (copier-coller le Markdown)"
echo ""
