# Giám sát dung lượng disk — OpenShift dev-ocp (ocp01.npd.co)

Runbook theo dõi **PVC/NFS**, **độ nở dữ liệu**, **retention**, và **disk trên master/worker node** — tránh out-of-disk trên lab bare metal.

Dùng kèm:

- [INSTALL-NFS-CSI.md](./INSTALL-NFS-CSI.md) — NFS CSI, `mountPermissions`
- [INSTALL-TROUBLESHOOTING.md](./INSTALL-TROUBLESHOOTING.md) — lỗi PVC, Harbor, Postgres
- [../../OCP-DEPLOY-GUIDE.md](../../OCP-DEPLOY-GUIDE.md)

---

## Mục lục

1. [Tổng quan kiến trúc lưu trữ](#1-tổng-quan-kiến-trúc-lưu-trữ)
2. [PVC trên cluster (quota)](#2-pvc-trên-cluster-quota)
3. [Dung lượng thực tế trên NFS](#3-dung-lượng-thực-tế-trên-nfs)
4. [Dung lượng từ trong pod](#4-dung-lượng-từ-trong-pod)
5. [Theo dõi độ nở (growth rate)](#5-theo-dõi-độ-nở-growth-rate)
6. [Disk master / worker node](#6-disk-master--worker-node)
7. [Thành phần cần retention](#7-thành-phần-cần-retention)
8. [Prometheus OCP (RAM + disk)](#8-prometheus-ocp-ram--disk)
9. [Ngưỡng cảnh báo lab](#9-ngưỡng-cảnh-báo-lab)
10. [Audit một lần (bastion + NFS)](#10-audit-một-lần-bastion--nfs)
11. [Script tự động](#11-script-tự-động)

---

## 1. Tổng quan kiến trúc lưu trữ

| Lớp | Vị trí | Ghi chú |
|-----|--------|---------|
| **PVC app/infra** | NFS `10.100.1.180:/shares/registry` | Subdir `${namespace}/${pvc-name}` (StorageClass `nfs-csi`) |
| **Disk node** | Master / Worker (RHCOS) | Root `/`, `/var`, CRI-O images, kubelet, logs |
| **Master riêng** | `/var/lib/etcd` | DB cluster — **không xóa tay** |
| **Cluster monitoring** | `openshift-monitoring` | Prometheus platform — thường top CPU/RAM |

**Quan trọng:** `oc get pvc` chỉ cho **quota cấp phát** (vd. `1Gi`, `200Gi`), không phải dung lượng đã dùng. Đo thực tế: **NFS `du`** hoặc **`df`/`du` trong pod**.

### PVC theo GitOps (tham chiếu)

| Namespace | Component | Size (values) |
|-----------|-----------|---------------|
| `postgres` | Postgres primary + read | 1Gi ×2 |
| `redis` | Redis master + replicas | 20Gi ×4 |
| `minio` | MinIO | 200Gi |
| `platform` | Harbor, Jenkins | 1–10Gi |
| `observability` | Coroot ClickHouse | 20Gi |

Postgres **1Gi** là rủi ro cao nhất nếu không theo dõi.

---

## 2. PVC trên cluster (quota)

Chạy trên **bastion** (`oc login`):

```bash
# Tất cả PVC
oc get pvc -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName,SIZE:.spec.resources.requests.storage,STATUS:.status.phase,VOLUME:.spec.volumeName' \
| sort

# Chỉ nfs-csi
oc get pvc -A | grep nfs-csi

# PV (cluster-scoped — không dùng -n)
oc get pv -o custom-columns=\
'NAME:.metadata.name,SC:.spec.storageClassName,SIZE:.spec.capacity.storage,CLAIM:.spec.claimRef.namespace/.spec.claimRef.name,STATUS:.status.phase'

# PVC nhỏ (dễ full trước)
oc get pvc -A -o json | jq -r '
  .items[] | select(.status.phase=="Bound") |
  "\(.metadata.namespace)/\(.metadata.name)  \(.spec.resources.requests.storage)  \(.spec.storageClassName)"
' | grep -E '1Gi|2Gi|5Gi|8Gi'

# Events liên quan disk
oc get events -A --field-selector reason=FailedMount,reason=VolumeResizeFailed,reason=Evicted \
  --sort-by=.lastTimestamp | tail -20
```

---

## 3. Dung lượng thực tế trên NFS

Chạy trên **NFS server** (`10.100.1.180`, share `/shares/registry`):

```bash
# Tổng disk
df -h /shares/registry

# Theo namespace
du -sh /shares/registry/* 2>/dev/null | sort -h

# Theo PVC (subDir = ns/pvc-name)
du -sh /shares/registry/*/* 2>/dev/null | sort -h

# Top 20 PVC nặng nhất
du -sh /shares/registry/*/* 2>/dev/null | sort -hr | head -20

# Nhóm infra chính
du -sh /shares/registry/postgres/* \
       /shares/registry/redis/* \
       /shares/registry/minio/* \
       /shares/registry/platform/* \
       /shares/registry/observability/* 2>/dev/null
```

---

## 4. Dung lượng từ trong pod

Khi pod **Running** — ước lượng % dùng so với mount:

```bash
# Postgres — DB size
oc exec -n postgres postgres-ha-postgresql-primary-0 -c postgresql -- \
  psql -U postgres -c "
SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database ORDER BY pg_database_size(datname) DESC;

SELECT pg_size_pretty(sum(size)) AS wal_total FROM pg_ls_waldir() AS f(size bigint);
"

oc exec -n postgres postgres-ha-postgresql-primary-0 -c postgresql -- \
  sh -c 'df -h /bitnami/postgresql; du -sh /bitnami/postgresql/data/* 2>/dev/null | sort -h'

# Redis master
oc exec -n redis $(oc get pod -n redis -l app.kubernetes.io/component=master -o name | head -1) -- \
  sh -c 'df -h; du -sh /data/* 2>/dev/null'

# MinIO
oc exec -n minio deploy/minio -- sh -c \
  'df -h /bitnami/minio/data; du -sh /bitnami/minio/data/* 2>/dev/null | sort -hr | head -10'

# Jenkins
oc exec -n platform jenkins-0 -c jenkins -- df -h /var/jenkins_home 2>/dev/null

# Coroot ClickHouse
oc exec -n observability \
  $(oc get pod -n observability -l app.kubernetes.io/name=clickhouse -o name 2>/dev/null | head -1) -- \
  df -h /bitnami/clickhouse 2>/dev/null
```

MinIO theo bucket (nếu `mc` trong image):

```bash
oc exec -n minio deploy/minio -- mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" 2>/dev/null
oc exec -n minio deploy/minio -- mc du local/movies local/posters local/raw 2>/dev/null
```

---

## 5. Theo dõi độ nở (growth rate)

### Snapshot NFS (khuyến nghị: hàng ngày hoặc hàng tuần)

Trên **NFS server**:

```bash
TS=$(date +%Y%m%d-%H%M)
mkdir -p /var/log/pvc-audit
{
  echo "=== $(date -Is) ==="
  df -h /shares/registry
  echo "--- per PVC ---"
  du -sh /shares/registry/*/* 2>/dev/null | sort -hr
} | tee "/var/log/pvc-audit/pvc-usage-${TS}.log"
```

So sánh 2 lần (24h / 7 ngày):

```bash
diff -u /var/log/pvc-audit/pvc-usage-20250721-0600.log \
        /var/log/pvc-audit/pvc-usage-20250722-0600.log | grep -E '^\+|^\-' | head -40
```

### Snapshot node disk

Xem [§6](#6-disk-master--worker-node) và [§11 Script](#11-script-tự-động).

### Cron gợi ý (NFS)

```cron
0 6 * * * root TS=$(date +\%Y\%m\%d-\%H\%M); mkdir -p /var/log/pvc-audit; du -sh /shares/registry/*/* 2>/dev/null | sort -hr | tee /var/log/pvc-audit/pvc-${TS}.log; df -h /shares/registry >> /var/log/pvc-audit/pvc-${TS}.log
```

---

## 6. Disk master / worker node

Disk node **khác** NFS: container images, kubelet, logs, etcd (master).

### Tổng quan (bastion)

```bash
oc get nodes -o wide
oc adm top nodes

oc get nodes -o custom-columns=\
'NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,DISK:.status.conditions[?(@.type=="DiskPressure")].status,MEM:.status.conditions[?(@.type=="MemoryPressure")].status'
```

`DiskPressure=True` → node thiếu disk; pod có thể bị evict.

### Chi tiết từng node (`oc debug`)

RHCOS — dùng debug pod:

```bash
NODE=worker01   # hoặc master01

oc debug node/$NODE -- chroot /host bash -c '
echo "=== df ==="
df -hT | grep -E "^Filesystem|/dev/|sysroot|/var|/tmp|/boot"

echo "=== inodes ==="
df -hi | grep -E "^Filesystem|/dev/|sysroot"

echo "=== /var top-level ==="
du -xhd1 /var 2>/dev/null | sort -hr | head -15

echo "=== dirs thường nở ==="
for d in /var/lib/containers /var/lib/kubelet /var/log /var/lib/etcd /tmp; do
  [ -d "$d" ] && du -sh "$d" 2>/dev/null
done

echo "=== CRI-O images count ==="
crictl images 2>/dev/null | wc -l
du -sh /var/lib/containers/storage 2>/dev/null
'
```

**Tất cả node:**

```bash
for NODE in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "########## $NODE ##########"
  oc debug node/$NODE -- chroot /host df -hP / /var /var/lib/containers /var/lib/kubelet /var/log 2>/dev/null \
    | grep -E 'Filesystem|/dev|sysroot|containers|kubelet|/var/log'
  echo
done
```

### Master vs worker — chỗ cần xem

| Node | Thư mục | Ghi chú |
|------|---------|---------|
| Master | `/var/lib/etcd` | Chỉ compact/defrag theo doc OCP |
| Master/Worker | `/var/lib/containers/storage` | Image CRI-O — prune khi cần |
| Worker | `/var/lib/kubelet/pods` | emptyDir, log pod |
| All | `/var/log` | journal, audit |

**etcd (master):**

```bash
oc exec -n openshift-etcd $(oc get pod -n openshift-etcd -l app=etcd -o name | head -1) -c etcdctl -- \
  etcdctl endpoint status -w table 2>/dev/null
```

### Dọn image trên worker (lab — cẩn thận)

```bash
NODE=worker01
oc debug node/$NODE -- chroot /host bash -c '
echo "Before:"; df -h /var
crictl rmi --prune 2>/dev/null || true
echo "After:"; df -h /var
du -sh /var/lib/containers/storage
'
```

### Metric Prometheus (nếu cluster monitoring bật)

Console → **Observe → Metrics**, hoặc:

```promql
# % disk root
100 - (node_filesystem_avail_bytes{mountpoint="/",fstype!="tmpfs"} * 100
  / node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"})

node_filesystem_avail_bytes{mountpoint="/"}
```

```bash
oc get route -n openshift-monitoring prometheus-k8s -o jsonpath='{.spec.host}{"\n"}' 2>/dev/null
```

---

## 7. Thành phần cần retention

| Thành phần | Lưu ở đâu | Tăng nhanh? | Hành động |
|------------|-----------|-------------|-----------|
| **Postgres** | NFS PVC 1Gi | Cao | Theo dõi `pg_database_size`; tăng PVC; vacuum; prune data test |
| **MinIO** | NFS 200Gi | Cao (video/raw) | Lifecycle bucket `raw/`; xóa object test |
| **Harbor registry** | NFS platform | Cao | GC registry + retention tag policy (UI hoặc cron) |
| **Jenkins** | NFS 8Gi | TB | Discard old builds; dọn workspace |
| **Redis** | NFS 20Gi | Thấp–TB | `maxmemory` + eviction nếu cần |
| **Coroot ClickHouse** | NFS 20Gi | TB | Retention trace/metric trong Coroot |
| **Prometheus OCP** | PVC platform | Rất cao | Giảm `retention` / `retentionSize` (§8) |
| **Container images** | Node `/var` | Cao (CI) | `crictl rmi --prune`; kubelet image GC |
| **etcd** | Master | Chậm | Backup + maintenance OCP — không xóa thư mục |

### Harbor GC

```bash
du -sh /shares/registry/platform/*harbor* 2>/dev/null
# UI: Administration → Clean Up / Garbage Collection
```

### Jenkins

```bash
oc exec -n platform jenkins-0 -c jenkins -- \
  du -sh /var/jenkins_home/* 2>/dev/null | sort -hr | head -15
```

Job: **Discard old builds** (lab: giữ 7–14 bản).

---

## 8. Prometheus OCP (RAM + disk)

Prometheus cluster monitoring thường **top CPU/RAM** — bình thường trên lab nhỏ.

```bash
oc top pod -n openshift-monitoring --sort-by=memory | head -10
oc get pvc -n openshift-monitoring
oc -n openshift-monitoring get cm cluster-monitoring-config -o yaml 2>/dev/null | grep -A30 prometheusK8s
```

Giảm tải lab — patch ConfigMap (CMO rollout lại prometheus):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    prometheusK8s:
      retention: 24h
      retentionSize: 10GB
      resources:
        requests:
          cpu: 200m
          memory: 1Gi
        limits:
          cpu: "1"
          memory: 2Gi
```

```bash
oc apply -f cluster-monitoring-config.yaml
oc get pods -n openshift-monitoring -w
```

**Lưu ý:** `limits.memory` quá thấp → OOMKill, mất metric tạm thời.

---

## 9. Ngưỡng cảnh báo lab

| Vị trí | Cảnh báo | Critical |
|--------|----------|----------|
| NFS `/shares/registry` | >80% | >90% |
| Node `/` hoặc `/var` | >75% | >90% |
| Postgres PVC 1Gi | >70% used | >85% |
| Prometheus retention | trend tăng liên tục | OOM / PVC full |

---

## 10. Audit một lần (bastion + NFS)

### Bastion

```bash
echo "=== Nodes ==="
oc get nodes -o custom-columns=NAME:.metadata.name,DISK:.status.conditions[?(@.type=="DiskPressure")].status

echo "=== PVC quota ==="
oc get pvc -A --no-headers | awk '{print $1,$2,$4,$5}' | column -t

echo "=== Top memory pods ==="
oc top pod -A --sort-by=memory 2>/dev/null | head -15

for NODE in $(oc get nodes -o name); do
  echo "== $NODE =="
  oc debug $NODE -- chroot /host df -hP / /var 2>/dev/null | tail -n +2
done
```

### NFS server

```bash
df -h /shares/registry
du -sh /shares/registry/*/* 2>/dev/null | sort -hr | head -15
```

---

## 11. Script tự động

Script bastion (node + PVC list):  
`./phase9-gitops-platform/environments/dev-ocp/scripts/disk-audit.sh`

```bash
chmod +x phase9-gitops-platform/environments/dev-ocp/scripts/disk-audit.sh
./phase9-gitops-platform/environments/dev-ocp/scripts/disk-audit.sh
./phase9-gitops-platform/environments/dev-ocp/scripts/disk-audit.sh /var/log/disk-audit-$(date +%Y%m%d).log
```

Script NFS (chạy trên NFS server):  
`./phase9-gitops-platform/environments/dev-ocp/scripts/nfs-pvc-audit.sh`

Cron bastion (6h sáng):

```cron
0 6 * * * root /path/to/disk-audit.sh /var/log/disk-audit/ocp-$(date +\%Y\%m\%d).log
```

---

## Liên kết

| Doc | Nội dung |
|-----|----------|
| [INSTALL-NFS-CSI.md](./INSTALL-NFS-CSI.md) | Cài NFS CSI, `mountPermissions` |
| [INSTALL-TROUBLESHOOTING.md](./INSTALL-TROUBLESHOOTING.md) | Permission denied PVC, Harbor pgdata |
| [INSTALL-SCC-HARDENED.md](./INSTALL-SCC-HARDENED.md) | SCC Bitnami UID 1001 + NFS |
