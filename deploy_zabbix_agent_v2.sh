#!/bin/bash

# deploy_zabbix_agent_v2.sh
# Usage: bash deploy_zabbix_agent_v2.sh [ZABBIX_SERVER_IP]
# Exemple: bash <(curl -fsSL https://raw.githubusercontent.com/Radiowar1792/script-bash/main/deploy_zabbix_agent_v2.sh) 172.16.10.151
#
# Différences vs v1 :
#   - Génère un PSK unique par host (32 bytes hex)
#   - Active le chiffrement TLS PSK Active mode
#   - Préserve /etc/apt/sources.list.d/zabbix.list s'il existe déjà
#   - Affiche en fin de script les valeurs à coller dans Zabbix UI

set -e

# ─── Configuration ───────────────────────────────────────────
ZABBIX_SERVER="${1:-172.16.10.151}"
ZABBIX_VERSION="7.0"
HOSTNAME=$(hostname)
HOST_IP=$(hostname -I | awk '{print $1}')
PSK_IDENTITY="psk-${HOSTNAME}"
PSK_FILE="/etc/zabbix/zabbix_agent2.psk"
# ─────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════╗"
echo "║   Installation Zabbix Agent 2 + PSK         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Serveur Zabbix : $ZABBIX_SERVER"
echo "  Hostname       : $HOSTNAME"
echo "  IP             : $HOST_IP"
echo "  PSK identity   : $PSK_IDENTITY"
echo ""

# Vérification root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Ce script doit être exécuté en root"
    exit 1
fi

# Vérification connectivité vers le serveur Zabbix
echo "[1/7] Vérification connectivité vers $ZABBIX_SERVER:10051..."
if ! nc -z -w3 "$ZABBIX_SERVER" 10051 2>/dev/null; then
    echo "⚠️  Port 10051 non joignable — l'agent sera installé mais vérifiez le firewall."
fi

# Nettoyage ancienne installation (PRÉSERVATION DU REPO ZABBIX)
echo "[2/7] Nettoyage ancienne installation..."
systemctl stop zabbix-agent2 2>/dev/null || true
apt remove --purge -y zabbix-agent zabbix-agent2 2>/dev/null || true
# ⚠️ FIX vs v1 : on ne supprime PLUS aveuglément zabbix.list
# (cas du serveur Zabbix où ce fichier doit rester en place pour les paquets server)
# rm -f /etc/apt/sources.list.d/zabbix.list   ← NE PAS DÉCOMMENTER
apt autoremove -y 2>/dev/null || true

# Ajout du dépôt Zabbix (idempotent : ne réécrase pas si déjà OK)
echo "[3/7] Vérification du dépôt Zabbix ${ZABBIX_VERSION}..."
if ! grep -q "repo.zabbix.com/zabbix/${ZABBIX_VERSION}" /etc/apt/sources.list.d/zabbix.list 2>/dev/null; then
    echo "      → Dépôt absent, installation du release-package..."
    DEB_FILE="zabbix-release_latest_${ZABBIX_VERSION}+debian12_all.deb"
    wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/${DEB_FILE}" -O /tmp/${DEB_FILE}
    dpkg -i --force-confmiss /tmp/${DEB_FILE}
    rm -f /tmp/${DEB_FILE}
else
    echo "      → Dépôt déjà présent, on conserve."
fi
apt update -qq

# Installation
echo "[4/7] Installation de zabbix-agent2..."
apt install -y zabbix-agent2

# Génération du PSK
echo "[5/7] Génération du PSK..."
PSK_KEY=$(openssl rand -hex 32)
echo "$PSK_KEY" > "$PSK_FILE"
chmod 640 "$PSK_FILE"
chown zabbix:zabbix "$PSK_FILE"
echo "      → PSK écrit dans $PSK_FILE"

# Configuration de l'agent (incluant PSK)
echo "[6/7] Configuration de l'agent..."
CONF="/etc/zabbix/zabbix_agent2.conf"

# Stop le service s'il a démarré automatiquement
systemctl stop zabbix-agent2 2>/dev/null || true

# Lignes standard
sed -i "s|^Server=.*|Server=${ZABBIX_SERVER}|" "$CONF"
sed -i "s|^ServerActive=.*|ServerActive=${ZABBIX_SERVER}|" "$CONF"
sed -i "s|^Hostname=.*|Hostname=${HOSTNAME}|" "$CONF"

# Tuning
grep -q "^# BufferSize=" "$CONF" && sed -i "s|^# BufferSize=.*|BufferSize=100|" "$CONF" || true
grep -q "^# Timeout=" "$CONF" && sed -i "s|^# Timeout=.*|Timeout=10|" "$CONF" || true

# Configuration TLS PSK
# On désactive les anciennes lignes TLS si présentes (idempotent)
sed -i "s|^TLSConnect=.*|# &|" "$CONF" 2>/dev/null || true
sed -i "s|^TLSAccept=.*|# &|" "$CONF" 2>/dev/null || true
sed -i "s|^TLSPSKIdentity=.*|# &|" "$CONF" 2>/dev/null || true
sed -i "s|^TLSPSKFile=.*|# &|" "$CONF" 2>/dev/null || true

# On ajoute notre bloc TLS propre en fin de fichier
cat >> "$CONF" << EOF

# ─── TLS PSK (ajouté par deploy_zabbix_agent_v2.sh) ───
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=${PSK_IDENTITY}
TLSPSKFile=${PSK_FILE}
EOF

# Démarrage après configuration
systemctl daemon-reload
systemctl enable --now zabbix-agent2

# Vérification finale
sleep 3
echo "[7/7] Vérification..."
echo ""
echo "─────────────────────────────────────────────"
if systemctl is-active --quiet zabbix-agent2; then
    echo "✅ zabbix-agent2 actif"
    echo ""
    echo "📋 INFOS À RENSEIGNER DANS ZABBIX UI :"
    echo "─────────────────────────────────────────────"
    echo ""
    echo "  ➡️  Configuration > Hosts > Create host"
    echo ""
    echo "      Host name      : $HOSTNAME"
    echo "      Visible name   : $HOSTNAME"
    echo "      Templates      : Linux by Zabbix agent active   ← ATTENTION : 'active' à la fin"
    echo "      Host groups    : (selon catégorie ci-dessous)"
    echo "      Interfaces     : Agent  IP=${HOST_IP}  port=10050  (juste pour la forme, mode active)"
    echo ""
    echo "  ➡️  Onglet Encryption (du host) :"
    echo ""
    echo "      Connections to host       : PSK"
    echo "      Connections from host     : ☑ PSK"
    echo "      PSK identity              : ${PSK_IDENTITY}"
    echo "      PSK                       : ${PSK_KEY}"
    echo ""
    echo "─────────────────────────────────────────────"
    echo ""
    echo "💾 Sauvegarde de la PSK dans ton gestionnaire de mots de passe :"
    echo "      Nom    : zabbix-psk-${HOSTNAME}"
    echo "      Valeur : ${PSK_KEY}"
    echo "      Date   : $(date +%Y-%m-%d)"
    echo "─────────────────────────────────────────────"
else
    echo "❌ zabbix-agent2 n'a pas démarré"
    echo "   Logs : journalctl -u zabbix-agent2 -n 30"
    exit 1
fi
