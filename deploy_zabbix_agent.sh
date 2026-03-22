#!/bin/bash
# deploy_zabbix_agent.sh
# Usage: bash deploy_zabbix_agent.sh [ZABBIX_SERVER_IP]
# Exemple: bash deploy_zabbix_agent.sh 172.16.10.151

set -e

# ─── Configuration ───────────────────────────────────────────
ZABBIX_SERVER="${1:-172.16.10.151}"   # IP par défaut, overridable en argument
ZABBIX_VERSION="7.0"
HOSTNAME=$(hostname)
DEBIAN_CODENAME=$(lsb_release -sc 2>/dev/null || echo "bookworm")
ARCH=$(dpkg --print-architecture)
# ─────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════╗"
echo "║        Installation Zabbix Agent 2           ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Serveur Zabbix : $ZABBIX_SERVER"
echo "  Hostname       : $HOSTNAME"
echo "  OS             : $DEBIAN_CODENAME ($ARCH)"
echo ""

# Vérification root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Ce script doit être exécuté en root (sudo)"
  exit 1
fi

# Vérification connectivité vers le serveur Zabbix
echo "[1/5] Vérification de la connectivité vers $ZABBIX_SERVER..."
if ! nc -z -w3 "$ZABBIX_SERVER" 10051 2>/dev/null; then
  echo "⚠️  Attention : le port 10051 de $ZABBIX_SERVER n'est pas joignable."
  echo "   L'agent sera installé mais vérifiez le firewall."
fi

# Suppression ancienne installation si existante
echo "[2/5] Nettoyage d'une éventuelle ancienne installation..."
apt remove --purge -y zabbix-agent zabbix-agent2 2>/dev/null || true
rm -f /etc/apt/sources.list.d/zabbix.list

# Téléchargement et installation du dépôt Zabbix
echo "[3/5] Ajout du dépôt Zabbix ${ZABBIX_VERSION}..."
DEB_FILE="zabbix-release_latest_${ZABBIX_VERSION}+debian12_all.deb"
wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/${DEB_FILE}" -O /tmp/${DEB_FILE}
dpkg -i /tmp/${DEB_FILE}
apt update -qq

# Installation de zabbix-agent2
echo "[4/5] Installation de zabbix-agent2..."
apt install -y zabbix-agent2

# Configuration
echo "[5/5] Configuration de l'agent..."
CONF="/etc/zabbix/zabbix_agent2.conf"

sed -i "s/^Server=.*/Server=${ZABBIX_SERVER}/" "$CONF"
sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER}/" "$CONF"
sed -i "s/^Hostname=.*/Hostname=${HOSTNAME}/" "$CONF"

# Active le buffer et les logs propres
sed -i "s/^# BufferSize=.*/BufferSize=100/" "$CONF"
sed -i "s/^# Timeout=.*/Timeout=10/" "$CONF"

# Démarrage du service
systemctl daemon-reload
systemctl enable --now zabbix-agent2

# ─── Vérification finale ──────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────"
if systemctl is-active --quiet zabbix-agent2; then
  echo "✅ zabbix-agent2 actif sur $HOSTNAME"
  echo "   Serveur    : $ZABBIX_SERVER"
  echo "   Config     : $CONF"
  echo "   Port local : $(ss -tlnp | grep zabbix | awk '{print $4}')"
else
  echo "❌ zabbix-agent2 n'a pas démarré"
  echo "   Logs : journalctl -u zabbix-agent2 -n 20"
  exit 1
fi
echo "─────────────────────────────────────────────"
echo ""
echo "➡️  Dans Zabbix UI : Configuration > Hosts > Create Host"
echo "   Hostname : $HOSTNAME"
echo "   IP       : $(hostname -I | awk '{print $1}')"
