#!/usr/bin/env bash
# Audit PVC usage trên NFS share /shares/registry (chạy trên NFS server).
# Usage:
#   ./nfs-pvc-audit.sh
#   ./nfs-pvc-audit.sh /var/log/pvc-audit/pvc-$(date +%Y%m%d).log
set -euo pipefail

SHARE="${NFS_SHARE:-/shares/registry}"
OUT="${1:-}"

log() {
  if [[ -n "${OUT}" ]]; then
    mkdir -p "$(dirname "${OUT}")"
    tee -a "${OUT}"
  else
    cat
  fi
}

if [[ ! -d "${SHARE}" ]]; then
  echo "ERROR: ${SHARE} not found" >&2
  exit 1
fi

{
  echo "=== nfs-pvc-audit $(date -Is) share=${SHARE} ==="
  echo

  echo "=== df ==="
  df -h "${SHARE}"
  echo

  echo "=== per namespace ==="
  du -sh "${SHARE}"/* 2>/dev/null | sort -h || true
  echo

  echo "=== per PVC (top 30) ==="
  du -sh "${SHARE}"/*/* 2>/dev/null | sort -hr | head -30 || true
  echo

  echo "=== infra groups ==="
  for ns in postgres redis minio platform observability npd-movie argocd vault kong; do
    if [[ -d "${SHARE}/${ns}" ]]; then
      echo "-- ${ns} --"
      du -sh "${SHARE}/${ns}"/* 2>/dev/null | sort -hr | head -10 || true
    fi
  done
  echo

  echo "=== Done ==="
} | log

if [[ -n "${OUT}" ]]; then
  echo "Saved: ${OUT}"
fi
