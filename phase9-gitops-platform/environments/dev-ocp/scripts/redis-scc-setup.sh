#!/usr/bin/env bash
# Redis Bitnami trên OCP + NFS: SCC UID 1001 (cùng mô hình postgres/minio).
#
#   ./phase9-gitops-platform/environments/dev-ocp/scripts/redis-scc-setup.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
NS="${REDIS_NS:-redis}"
SCC="redis-uid1001"
SA="${REDIS_SA:-redis-ha}"

echo "==> Namespace ${NS}"
oc create ns "${NS}" --dry-run=client -o yaml | oc apply -f -

echo "==> ServiceAccount ${SA}"
oc create serviceaccount "${SA}" -n "${NS}" --dry-run=client -o yaml | oc apply -f -

echo "==> Apply SCC ${SCC}"
oc apply -f "${REPO_ROOT}/phase9-gitops-platform/gitops-platform/manifests/redis-prereq/redis-scc.yaml"

echo "==> Bind SCC ${SCC} → SA ${SA} (+ default)"
oc adm policy add-scc-to-user "${SCC}" -z "${SA}" -n "${NS}"
oc adm policy add-scc-to-user "${SCC}" -z default -n "${NS}" 2>/dev/null || true

echo ""
echo "==> NFS (trên NFS server) — owner 1001:"
echo "  chown -R 1001:1001 /shares/registry/redis/"
echo "  chmod -R u+rwX,g+rwX /shares/registry/redis/"
echo ""
echo "  oc delete pod -n ${NS} -l app.kubernetes.io/name=redis --force --grace-period=0"
echo ""
echo "Kiểm tra: oc exec -n ${NS} <pod> -- id   # kỳ vọng uid=1001"
