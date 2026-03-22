#!/bin/bash
# deploy_promtail.sh
# Usage: bash deploy_promtail.sh [LOKI_IP]
# Exemple: bash <(curl -fsSL https://raw.githubusercontent.com/Radiowar1792/script-bash/main/deploy_promtail.sh) 172.16.10.153

set -e

# ─── Configuration ───────────────────────────────────────────
LOKI_SERVER="${1:-172.16.10.153}"
LOKI_PORT="3100"
PROMTAIL_VERSION="3.0.0"
HOSTNAME=$(hostname)
HOST_IP=$(hostname -I | awk '{print $1}')
ARCH="amd64"
# ─────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════╗"
echo "║          Installation Promtail               ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Serveur Loki : $LOKI_SERVER:$LOKI_PORT"
echo "  Hostname     : $HOSTNAME"
echo "  IP           : $HOST_IP"
echo ""

# Vérification root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Ce script doit être exécuté en root"
  exit 1
fi

# Vérification dépendances
for cmd in wget unzip curl; do
  if ! command -v $cmd &>/dev/null; then
    echo "📦 Installation de $cmd..."
    apt install -y $cmd
  fi
done

# Vérification connectivité Loki
echo "[1/5] Vérification connectivité vers $LOKI_SERVER:$LOKI_PORT..."
if ! nc -z -w3 "$LOKI_SERVER" "$LOKI_PORT" 2>/dev/null; then
  echo "⚠️  Port $LOKI_PORT non joignable sur $LOKI_SERVER — vérifiez que Loki tourne."
fi

# Nettoyage ancienne installation
echo "[2/5] Nettoyage ancienne installation..."
systemctl stop promtail 2>/dev/null || true
rm -f /usr/local/bin/promtail
rm -f /etc/systemd/system/promtail.service

# Téléchargement et installation
echo "[3/5] Téléchargement de Promtail v${PROMTAIL_VERSION}..."
cd /tmp
wget -q "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-${ARCH}.zip" -O promtail.zip
unzip -q -o promtail.zip
chmod +x "promtail-linux-${ARCH}"
mv "promtail-linux-${ARCH}" /usr/local/bin/promtail
rm -f promtail.zip
cd -

# Création utilisateur système
id promtail &>/dev/null || useradd --no-create-home --shell /bin/false promtail
usermod -aG systemd-journal promtail 2>/dev/null || true

# Configuration
echo "[4/5] Configuration de Promtail..."
mkdir -p /etc/promtail
mkdir -p /var/lib/promtail

cat > /etc/promtail/config.yml << EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://${LOKI_SERVER}:${LOKI_PORT}/loki/api/v1/push

scrape_configs:

  # Logs système généraux
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          host: ${HOSTNAME}
          __path__: /var/log/*.log

  # Logs systemd (journald)
  - job_name: journald
    journal:
      max_age: 12h
      labels:
        job: systemd
        host: ${HOSTNAME}
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: unit

EOF

# Ajout logs spécifiques selon les services détectés
if [ -d "/var/log/nginx" ]; then
  echo "  → Nginx détecté, ajout de la collecte des logs nginx..."
  cat >> /etc/promtail/config.yml << EOF
  # Logs Nginx
  - job_name: nginx
    static_configs:
      - targets:
          - localhost
        labels:
          job: nginx
          host: ${HOSTNAME}
          __path__: /var/log/nginx/*.log
EOF
fi

if [ -d "/var/log/zabbix" ]; then
  echo "  → Zabbix détecté, ajout de la collecte des logs zabbix..."
  cat >> /etc/promtail/config.yml << EOF
  # Logs Zabbix
  - job_name: zabbix
    static_configs:
      - targets:
          - localhost
        labels:
          job: zabbix
          host: ${HOSTNAME}
          __path__: /var/log/zabbix/*.log
EOF
fi

if [ -d "/var/log/mysql" ] || [ -d "/var/log/mariadb" ]; then
  echo "  → MariaDB/MySQL détecté, ajout de la collecte des logs..."
  cat >> /etc/promtail/config.yml << EOF
  # Logs MariaDB/MySQL
  - job_name: mariadb
    static_configs:
      - targets:
          - localhost
        labels:
          job: mariadb
          host: ${HOSTNAME}
          __path__: /var/log/mysql/*.log
EOF
fi

# Permissions
chown -R promtail:promtail /etc/promtail /var/lib/promtail

# Service systemd
echo "[5/5] Création du service systemd..."
cat > /etc/systemd/system/promtail.service << EOF
[Unit]
Description=Promtail - Loki Log Collector
After=network.target

[Service]
User=promtail
Group=promtail
Type=simple
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/config.yml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now promtail

# Vérification finale
sleep 2
echo ""
echo "─────────────────────────────────────────────"
if systemctl is-active --quiet promtail; then
  echo "✅ Promtail actif sur $HOSTNAME"
  echo "   Loki          : http://${LOKI_SERVER}:${LOKI_PORT}"
  echo "   Status UI     : http://${HOST_IP}:9080"
  echo "   Config        : /etc/promtail/config.yml"
  echo ""
  echo "─────────────────────────────────────────────"
  echo "  ➡️  Dans Grafana : Connections > Data sources > Loki"
  echo "     URL : http://${LOKI_SERVER}:${LOKI_PORT}"
  echo "─────────────────────────────────────────────"
else
  echo "❌ Promtail n'a pas démarré"
  echo "   Logs : journalctl -u promtail -n 20"
  exit 1
fi
