#!/usr/bin/env bash
# Cài node_exporter (systemd, :9100) trên NFS server 10.100.1.180 để Prometheus đo disk thật của PVC nfs-csi
# (ScrapeConfig manifests/monitoring/scrape-nfs-server.yaml). Chạy trên NFS server:
#   sudo bash nfs-node-exporter-install.sh
#   NODE_EXPORTER_VERSION=1.9.1 ALLOW_FROM=10.100.1.0/24 sudo -E bash nfs-node-exporter-install.sh
set -euo pipefail

VERSION="${NODE_EXPORTER_VERSION:-1.9.1}"
ALLOW_FROM="${ALLOW_FROM:-10.100.1.0/24}"
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
esac

[[ $EUID -eq 0 ]] || { echo "Chạy bằng sudo"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
echo "==> node_exporter ${VERSION} (${ARCH})"
curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-${ARCH}.tar.gz" \
  | tar -xz -C "${TMP}"
install -m 0755 "${TMP}/node_exporter-${VERSION}.linux-${ARCH}/node_exporter" /usr/local/bin/node_exporter

id node_exporter >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter

# nfsd: thống kê NFS server (node_nfsd_*); diskstats/filesystem bật sẵn
cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus node_exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=:9100 \
  --collector.nfsd \
  --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/docker/.+)($|/)
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow from "${ALLOW_FROM}" to any port 9100 proto tcp
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${ALLOW_FROM} port port=9100 protocol=tcp accept"
  firewall-cmd --reload
fi

sleep 1
curl -fsS http://127.0.0.1:9100/metrics | grep -E '^node_disk_reads_completed_total' | head -5
echo "==> OK. Kiểm tra trên Prometheus: up{job=\"nfs-server\"}"
