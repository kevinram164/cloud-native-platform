#!/usr/bin/env bash
# Postgres Bitnami trên OCP + NFS: SCC UID 1001 (không restricted-v2).
# Một lần trên bastion sau khi merge GitOps, hoặc trước khi chờ Argo sync prereq.
#
#   ./phase9-gitops-platform/environments/dev-ocp/scripts/postgres-scc-setup.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${ROOT}/../../.." && pwd)"
NS="${POSTGRES_NS:-postgres}"
SCC="postgres-uid1001"
SA="${POSTGRES_SA:-postgres-ha-postgresql}"

echo "==> Namespace ${NS}"
oc create ns "${NS}" --dry-run=client -o yaml | oc apply -f -

echo "==> ServiceAccount ${SA}"
oc create serviceaccount "${SA}" -n "${NS}" --dry-run=client -o yaml | oc apply -f -

echo "==> Apply SCC ${SCC}"
oc apply -f "${REPO_ROOT}/phase9-gitops-platform/gitops-platform/manifests/postgres-prereq/postgres-scc.yaml"

echo "==> Bind SCC ${SCC} → SA ${SA} (+ default)"
oc adm policy add-scc-to-user "${SCC}" -z "${SA}" -n "${NS}"
oc adm policy add-scc-to-user "${SCC}" -z default -n "${NS}" 2>/dev/null || true

echo ""
echo "==> NFS (chạy trên NFS server) — owner phải khớp UID 1001:"
echo "  chown -R 1001:1001 /shares/registry/postgres/data-postgres-ha-postgresql-primary-0"
echo "  chown -R 1001:1001 /shares/registry/postgres/data-postgres-ha-postgresql-read-0"
echo "  chmod -R u+rwX,g+rwX /shares/registry/postgres/data-postgres-ha-postgresql-*"
echo ""
echo "==> Restart STS (sau khi Helm values đã pin runAsUser 1001 + sync Argo)"
echo "  oc delete pod -n ${NS} -l app.kubernetes.io/name=postgresql --force --grace-period=0"
echo ""
echo "Kiểm tra:"
echo "  oc get pod -n ${NS} -o jsonpath='{range .items[*]}{.metadata.name}{\" scc=\"}{.metadata.annotations.openshift\\.io/scc}{\"\\n\"}{end}'"
echo "  oc exec -n ${NS} postgres-ha-postgresql-primary-0 -c postgresql -- id"
