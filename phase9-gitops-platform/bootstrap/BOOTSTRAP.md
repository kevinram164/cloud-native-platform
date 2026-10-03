# Bootstrap — Cài platform lần đầu

Thứ tự triển khai:

1. **Platform + Vault + Infra** (repo này)
2. **CI/CD** (Jenkins → Harbor → bump tag trong repo app)
3. **App** (ArgoCD project của từng app, từ repo app)

Chi tiết: [K8S-DEPLOY-GUIDE.md](../K8S-DEPLOY-GUIDE.md)

---

## Giai đoạn 1 — Cluster + ArgoCD

| # | Thành phần | Cách cài | Ghi chú |
|---|------------|----------|---------|
| 1 | **Cụm kubeadm** | Cilium, metrics-server, HAProxy ingress | npd-route 10.100.1.46 làm ingress node |
| 2 | **ArgoCD** | Helm `argo/argo-cd`, `server.insecure=true` | TLS kết thúc ở f5-lb 10.100.1.100 |
| 3 | **AppProject** | `kubectl apply -f environments/dev-k8s/appproject.yaml` | Project `platform` |
| 4 | **GitHub repo** | Public — không cần credential | `cloud-native-platform@main` |

---

## Giai đoạn 2 — Platform

```bash
bash phase9-gitops-platform/environments/dev-k8s/apply-argocd.sh
```

| # | Thành phần | Sau sync | Ghi chú |
|---|------------|----------|---------|
| 1 | **NFS CSI + `nfs-csi`** | PVC Bound | `platform-csi-driver-nfs`, `platform-k8s-base` |
| 2 | **Vault + Agent Injector** | init, unseal, seed, `scripts/vault-setup-k8s-auth.sh` | [vault/README.md](../vault/README.md) |
| 3 | **Harbor** | project, robot `ci` + `k8s-pull` → Vault `platform/harbor`, `platform/harbor-pull` | |
| 4 | **Jenkins** | Admin từ Vault `platform/jenkins` qua injector | Pod chờ `vault-agent-init` đến khi Vault sẵn sàng |

---

## Giai đoạn 3 — Infra + observability

```bash
STAGE=infra bash phase9-gitops-platform/environments/dev-k8s/apply-argocd.sh
STAGE=observability bash phase9-gitops-platform/environments/dev-k8s/apply-argocd.sh
```

| # | Thành phần | Ghi chú |
|---|------------|---------|
| 1 | **Postgres, Redis** | Wave 0, values `environments/dev-k8s/values/` |
| 2 | **RabbitMQ** | Wave 1, admin từ Vault `rabbitmq/admin` qua injector |
| 3 | **Kong HA** | Wave 2, PreSync chờ PG Ready + tạo DB `kong` |
| 4 | **Strimzi, Kafka, Kafka UI** | |
| 5 | **Coroot, OTEL Collector** | |

> Bitnami chart dùng `https://charts.bitnami.com/bitnami`, không dùng OCI Docker Hub (ArgoCD hay lỗi `401 Unauthorized`).

---

## Giai đoạn 4 — CI/CD

| # | Bước | Công cụ |
|---|------|---------|
| 1 | Push code | GitHub repo app (vd. `banking-demo@dev-k8s`) |
| 2 | Build + push image | Jenkins + Kaniko → `npd-harbor.co` |
| 3 | Commit tag | Jenkins → `deploy/dev-k8s/values/values-images.yaml` trong repo app |

---

## Giai đoạn 5 — App

```bash
VAULT_TOKEN=<token> bash phase9-gitops-platform/environments/dev-k8s/scripts/create-harbor-pull-secret.sh
# Trong repo banking-demo (nhánh dev-k8s):
kubectl apply -f deploy/dev-k8s/argocd/appproject.yaml
kubectl apply -f deploy/dev-k8s/argocd/app-of-apps.yaml
```

Sau khi banking pods Running, import cấu hình Kong (trong repo banking-demo):

```bash
kubectl apply -f phase8-application-v3/kong-ha/kong-import-job.yaml
```

---

## Rollback

- ArgoCD UI → History → Rollback Application cụ thể.
- Image tag: revert commit `values-images.yaml` trong repo app.
- Secret: `vault kv rollback -version=<n> secret/<path>` rồi restart workload.
