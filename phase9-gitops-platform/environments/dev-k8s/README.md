# Environment: dev-k8s

ArgoCD + GitOps cho cụm kubeadm NPD (Cilium, HAProxy ingress, NFS CSI). Hướng dẫn đầy đủ: [K8S-DEPLOY-GUIDE.md](../../K8S-DEPLOY-GUIDE.md).

Chỉ chứa platform và infra dùng chung. Ứng dụng (banking, …) triển khai từ repo của app với AppProject riêng. Secret: Vault Agent Injector, không dùng ESO. Không dùng service mesh.

## Cấu trúc

| Đường dẫn | Nội dung |
|-----------|----------|
| `appproject.yaml` | AppProject `platform` |
| `argocd/applications/*-app-of-apps.yaml` | Điểm vào từng giai đoạn |
| `argocd/applications/platform/` | NFS CSI, StorageClass + SA, Ingress, Vault (+ injector), Harbor, Jenkins |
| `argocd/applications/infra/` | Postgres, Redis, RabbitMQ, Kong, Strimzi, Kafka, Kafka UI |
| `argocd/applications/observability/` | Coroot, OTEL Collector |
| `manifests/base/` | StorageClass `nfs-csi`, SA `jenkins-kaniko` |
| `manifests/ingress/` | Ingress HAProxy cho UI platform |
| `manifests/rabbitmq/` | RabbitMQ standalone (credential qua Vault Agent) |
| `values/` | Values Postgres, Redis, Kong, Coroot, OTEL |
| `scripts/vault-setup-k8s-auth.sh` | KV v2, auth kubernetes, policy + role cho injector |
| `scripts/create-harbor-pull-secret.sh` | Secret `harbor-pull-creds` từ Vault `platform/harbor-pull` |
| `scripts/nfs-reuse-prepare.sh` | Chạy trên NFS server: kiểm tra/backup/chown folder PVC cũ của OCP |
| `gitops-env.yaml` | IP, domain, registry của cụm |

## Thứ tự triển khai

| Bước | Lệnh | Giai đoạn |
|------|------|-----------|
| 0 | `scripts/nfs-reuse-prepare.sh --apply` trên NFS server (nếu dùng lại data OCP) | Storage |
| 1 | `bash apply-argocd.sh` | AppProject + platform |
| 2 | Init/unseal Vault, seed secret, `scripts/vault-setup-k8s-auth.sh` | Vault |
| 3 | `STAGE=infra bash apply-argocd.sh` | Infra |
| 4 | `STAGE=observability bash apply-argocd.sh` | Observability |
| 5 | `STAGE=all bash apply-argocd.sh` (tùy chọn) | Root app-of-apps |
| 6 | `scripts/create-harbor-pull-secret.sh`, rồi apply `deploy/dev-k8s/argocd` trong repo app | App |
