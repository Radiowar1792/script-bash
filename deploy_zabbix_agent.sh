#!/bin/bash
# deploy_zabbix_agent.sh
# Usage: bash deploy_zabbix_agent.sh [ZABBIX_SERVER_IP]
# Exemple: bash <(curl -fsSL https://raw.githubusercontent.com/Radiowar1792/script-bash/main/deploy_zabbix_agent.sh) 172.16.10.151

set -e

# ─── Configuration ───────────────────────────────────────────
ZABBIX_SERVER="${1:-172.16.10.151}"
ZABBIX_VERSION="7.0"
HOSTNAME=$(hostname)
HOST_IP=$(hostname -I | awk '{print $1}')
# ─────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════╗"
echo "║        Installation Zabbix Agent 2           ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Serveur Zabbix : $ZABBIX_SERVER"
echo "  Hostname       : $HOSTNAME"
echo "  IP             : $HOST_IP"
echo ""

# Vérification root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Ce script doit être exécuté en root"
  exit 1
fi

# Vérification connectivité vers le serveur Zabbix
echo "[1/5] Vérification connectivité vers $ZABBIX_SERVER:10051..."
if ! nc -z -w3 "$ZABBIX_SERVER" 10051 2>/dev/null; then
  echo "⚠️  Port 10051 non joignable — l'agent sera installé mais vérifiez le firewall."
fi

# Nettoyage ancienne installation
echo "[2/5] Nettoyage ancienne installation..."
systemctl stop zabbix-agent2 2>/dev/null || true
apt remove --purge -y zabbix-agent zabbix-agent2 2>/dev/null || true
rm -f /etc/apt/sources.list.d/zabbix.list
apt autoremove -y 2>/dev/null || true

# Ajout du dépôt Zabbix
echo "[3/5] Ajout du dépôt Zabbix ${ZABBIX_VERSION}..."
DEB_FILE="zabbix-release_latest_${ZABBIX_VERSION}+debian12_all.deb"
wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/${DEB_FILE}" -O /tmp/${DEB_FILE}
dpkg -i /tmp/${DEB_FILE}
rm -f /tmp/${DEB_FILE}
apt update -qq

# Installation
echo "[4/5] Installation de zabbix-agent2..."
apt install -y zabbix-agent2

# ─── FIX : configuration AVANT le premier démarrage ──────────
echo "[5/5] Configuration de l'agent..."
CONF="/etc/zabbix/zabbix_agent2.conf"

# Stop le service s'il a démarré automatiquement
systemctl stop zabbix-agent2 2>/dev/null || true

sed -i "s/^Server=.*/Server=${ZABBIX_SERVER}/" "$CONF"
sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER}/" "$CONF"
sed -i "s/^Hostname=.*/Hostname=${HOSTNAME}/" "$CONF"
sed -i "s/^# BufferSize=.*/BufferSize=100/" "$CONF"
sed -i "s/^# Timeout=.*/Timeout=10/" "$CONF"

# Démarrage après configuration
systemctl daemon-reload
systemctl enable --now zabbix-agent2
# ─────────────────────────────────────────────────────────────

# Vérification finale
sleep 2
echo ""
echo "─────────────────────────────────────────────"
if systemctl is-active --quiet zabbix-agent2; then
  RUNNING_HOSTNAME=$(journalctl -u zabbix-agent2 -n 10 --no-pager | grep "hostname:" | tail -1 | awk -F'[][]' '{print $2}')
  echo "✅ zabbix-agent2 actif"
  echo "   Hostname agent : $RUNNING_HOSTNAME"
  echo "   Serveur        : $ZABBIX_SERVER"
  echo ""
  echo "─────────────────────────────────────────────"
  echo "  ➡️  Dans Zabbix UI > Configuration > Hosts > Create Host"
  echo ""
  echo "     Host name  : $HOSTNAME"
  echo "     IP address : $HOST_IP"
  echo "     Port       : 10050"
  echo "     Host group : VM  (ou LXC selon le cas)"
  echo "     Template   : Linux by Zabbix agent"
  echo "─────────────────────────────────────────────"
else
  echo "❌ zabbix-agent2 n'a pas démarré"
  echo "   Logs : journalctl -u zabbix-agent2 -n 20"
  exit 1
fi
