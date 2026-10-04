#!/usr/bin/env bash
# Chuẩn bị dùng lại folder NFS của cụm OCP cũ cho dev-k8s. Chạy trên NFS server (10.100.1.180) bằng root.
#
# StorageClass nfs-csi (cũ và mới) cùng subDir ${namespace}/${pvc}: PVC cùng namespace + tên
# sẽ mount lại đúng folder cũ. OpenShift chạy pod với UID ngẫu nhiên (1000xxxxxx), còn K8s chạy
# UID của image → phải chown trước khi ArgoCD sync, nếu không pod báo Permission denied.
#
#   bash nfs-reuse-prepare.sh                     # chỉ kiểm tra (mặc định)
#   bash nfs-reuse-prepare.sh --backup /backup    # tar các folder nhỏ quan trọng (vault, DB)
#   bash nfs-reuse-prepare.sh --apply             # chown theo bảng
#   bash nfs-reuse-prepare.sh --apply --fresh-observability   # dời observability/*, logging/* (Coroot, OpenSearch cũ) sang _old
set -euo pipefail

SHARE="${NFS_SHARE:-/shares/registry}"
APPLY=false
BACKUP_DIR=""
FRESH_OBS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --backup) BACKUP_DIR="$2"; shift ;;
    --fresh-observability) FRESH_OBS=true ;;
    *) echo "Tham số không hợp lệ: $1" >&2; exit 1 ;;
  esac
  shift
done

[[ -d "${SHARE}" ]] || { echo "Không thấy ${SHARE}" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || { echo "Cần chạy bằng root" >&2; exit 1; }

# namespace/pvc (glob)                     uid:gid      backup  ghi chú
TABLE=$(cat <<'EOF'
vault/data-vault-0                         100:1000     yes     Vault file storage — cần unseal key + root token cũ
platform/jenkins                           1000:1000    no      jenkins_home (jobs, credentials, plugins)
platform/harbor-registry                   10000:10000  no      image layers
platform/harbor-jobservice                 10000:10000  no      job log
platform/database-data-harbor-database-*   999:999      yes     Harbor DB (project, robot, tag)
platform/data-harbor-redis-*               999:999      no      Harbor cache
postgres/data-postgres-ha-postgresql-*     1001:1001    yes     DB banking + kong
redis/redis-data-redis-ha-node-*           1001:1001    no      Redis HA
rabbit/rabbitmq-data                       999:999      no      RabbitMQ (user/vhost/queue cũ giữ nguyên)
kafka/data-0-npd-kafka-dual-role-*         1001:1001    no      Kafka KRaft — cần patch clusterId
minio/minio                                1001:1001    no      MinIO dùng chung — giữ root user/password cũ (IAM mã hoá bằng root cred)
EOF
)

echo "=== share ${SHARE}"
df -h "${SHARE}" | tail -1
echo
echo "=== Folder hiện có (namespace/pvc)"
du -sh "${SHARE}"/*/* 2>/dev/null | sed "s#${SHARE}/##" | sort -k2 || true
echo

echo "=== Đối chiếu với dev-k8s"
printf '%-48s %-6s %-22s %-12s %-9s %s\n' "PATH" "SIZE" "OWNER(root dir)" "WANT" "SAI OWNER" "GHI CHÚ"
missing=0
while read -r pattern want backup note; do
  [[ -z "${pattern}" ]] && continue
  found=false
  for dir in ${SHARE}/${pattern}; do
    [[ -d "${dir}" ]] || continue
    found=true
    rel="${dir#${SHARE}/}"
    size=$(du -sh "${dir}" 2>/dev/null | cut -f1)
    owner=$(stat -c '%u:%g' "${dir}")
    bad=$(find "${dir}" \( ! -uid "${want%:*}" -o ! -gid "${want#*:}" \) 2>/dev/null | wc -l)
    printf '%-48s %-6s %-22s %-12s %-9s %s\n' "${rel}" "${size}" "${owner}" "${want}" "${bad}" "${note}"

    if [[ -n "${BACKUP_DIR}" && "${backup}" == "yes" ]]; then
      mkdir -p "${BACKUP_DIR}"
      out="${BACKUP_DIR}/$(echo "${rel}" | tr '/' '_')-$(date +%Y%m%d%H%M).tar.gz"
      tar -C "${SHARE}" -czf "${out}" "${rel}"
      echo "    backup → ${out}"
    fi

    if ${APPLY} && [[ "${bad}" -gt 0 ]]; then
      chown -R "${want}" "${dir}"
      echo "    chown -R ${want} ✓"
    fi
  done
  if ! ${found}; then
    printf '%-48s %-6s %-22s %-12s %-9s %s\n' "${pattern}" "-" "MISSING" "${want}" "-" "sẽ tạo mới (data trống)"
    missing=$((missing + 1))
  fi
done <<< "${TABLE}"
echo

echo "=== Kafka cluster.id (dùng cho kubectl patch status.clusterId)"
grep -h '^cluster.id=' "${SHARE}"/kafka/data-0-npd-kafka-dual-role-*/kafka-log*/meta.properties 2>/dev/null | sort -u \
  || echo "Không thấy meta.properties — Kafka sẽ chạy cluster mới, đặt pauseReconciliation: false"
echo

# Coroot (observability/) và OpenSearch (logging/) cũ không dùng lại: ES/Prometheus mới tạo PVC trống
for ns in observability logging; do
  [[ -d "${SHARE}/${ns}" ]] || continue
  echo "=== ${ns} (telemetry cũ, không cần giữ)"
  du -sh "${SHARE}/${ns}"/* 2>/dev/null || true
  if ${APPLY} && ${FRESH_OBS}; then
    mv "${SHARE}/${ns}" "${SHARE}/${ns}_old_$(date +%Y%m%d)"
    echo "    đã dời sang ${ns}_old_*"
  fi
  echo
done

echo "=== Export NFS (kubelet đổi fsGroup cần no_root_squash)"
exportfs -v 2>/dev/null | grep -A1 "${SHARE}" || echo "Không đọc được exportfs"
echo
${APPLY} || echo "Chế độ kiểm tra. Chạy lại với --apply để chown (nên --backup trước)."
echo "Folder thiếu: ${missing}"
