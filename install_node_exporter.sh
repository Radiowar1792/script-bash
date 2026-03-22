#!/bin/bash
set -e

NODE_VERSION="1.8.0"
ARCH="amd64"

echo "[1/5] Téléchargement de node_exporter v${NODE_VERSION}..."
cd /tmp
wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_VERSION}/node_exporter-${NODE_VERSION}.linux-${ARCH}.tar.gz"

echo "[2/5] Extraction..."
tar xzf "node_exporter-${NODE_VERSION}.linux-${ARCH}.tar.gz"
cp "node_exporter-${NODE_VERSION}.linux-${ARCH}/node_exporter" /usr/local/bin/
chmod +x /usr/local/bin/node_exporter
rm -rf "node_exporter-${NODE_VERSION}.linux-${ARCH}"*

echo "[3/5] Création de l'utilisateur système..."
id node_exporter &>/dev/null || useradd --no-create-home --shell /bin/false node_exporter

echo "[4/5] Création du service systemd..."
cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

echo "[5/5] Activation du service..."
systemctl daemon-reload
systemctl enable --now node_exporter

echo ""
echo "✓ node_exporter actif sur le port 9100"
echo "  Test : curl http://$(hostname -I | awk '{print $1}'):9100/metrics | head"
