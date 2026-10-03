#!/usr/bin/env bash
# Audit disk: OpenShift nodes + PVC quota (bastion).
# Usage:
#   ./disk-audit.sh
#   ./disk-audit.sh /var/log/disk-audit-$(date +%Y%m%d).log
set -euo pipefail

OUT="${1:-}"
log() {
  if [[ -n "${OUT}" ]]; then
    tee -a "${OUT}"
  else
    cat
  fi
}

{
  echo "=== disk-audit $(date -Is) ==="
  echo

  echo "=== Nodes (DiskPressure) ==="
  oc get nodes -o custom-columns=\
'NAME:.metadata.name,ROLES:.metadata.labels.node-role\.kubernetes\.io/master,READY:.status.conditions[?(@.type=="Ready")].status,DISK:.status.conditions[?(@.type=="DiskPressure")].status,MEM:.status.conditions[?(@.type=="MemoryPressure")].status' \
    2>/dev/null || echo "WARN: oc get nodes failed"
  echo

  echo "=== oc adm top nodes ==="
  oc adm top nodes 2>/dev/null || echo "WARN: metrics-server unavailable"
  echo

  echo "=== PVC quota (all namespaces) ==="
  oc get pvc -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName,SIZE:.spec.resources.requests.storage,STATUS:.status.phase' \
    2>/dev/null | sort || true
  echo

  echo "=== PVC <= 8Gi (risk) ==="
  oc get pvc -A -o json 2>/dev/null | jq -r '
    .items[] | select(.status.phase=="Bound") |
    select(.spec.resources.requests.storage|test("Gi")) |
    select((.spec.resources.requests.storage|sub("Gi";"")|tonumber) <= 8) |
    "\(.metadata.namespace)/\(.metadata.name)  \(.spec.resources.requests.storage)"
  ' 2>/dev/null || echo "(jq optional)"
  echo

  echo "=== Top memory pods ==="
  oc top pod -A --sort-by=memory 2>/dev/null | head -15 || true
  echo

  echo "=== Node filesystem (oc debug) ==="
  for NODE in $(oc get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo "--- node/${NODE} ---"
    oc debug "node/${NODE}" -- chroot /host bash -c '
      df -hP / /var /var/lib/containers /var/lib/kubelet /var/log 2>/dev/null || df -hP /
      du -sh /var/lib/containers/storage /var/lib/kubelet/pods /var/log /var/lib/etcd 2>/dev/null || true
    ' 2>/dev/null || echo "WARN: debug failed for ${NODE}"
    echo
  done

  echo "=== Done ==="
  echo "NFS: chạy nfs-pvc-audit.sh trên NFS server (10.100.1.180)"
  echo "Doc: phase9-gitops-platform/environments/dev-ocp/DISK-MONITORING.md"
} | log

if [[ -n "${OUT}" ]]; then
  echo "Saved: ${OUT}"
fi
