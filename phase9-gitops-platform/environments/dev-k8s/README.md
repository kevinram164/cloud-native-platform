# Environment: dev-k8s

ArgoCD + GitOps cho cụm kubeadm NPD (Cilium, HAProxy ingress, NFS CSI). Hướng dẫn đầy đủ: [K8S-DEPLOY-GUIDE.md](../../K8S-DEPLOY-GUIDE.md).

Chỉ chứa platform và infra dùng chung. Ứng dụng (banking, …) triển khai từ repo của app với AppProject riêng. Secret: Vault Agent Injector, không dùng ESO. Không dùng service mesh.

## Cấu trúc

| Đường dẫn | Nội dung |
|-----------|----------|
| `appproject.yaml` | AppProject `platform` |
| `argocd/applications/*-app-of-apps.yaml` | Điểm vào từng giai đoạn |
| `argocd/applications/platform/` | NFS CSI, StorageClass + SA, Ingress, Vault (+ injector), Harbor, Jenkins, Keycloak |
| `argocd/applications/infra/` | Postgres, Redis, RabbitMQ, Kong, Strimzi, Kafka, Kafka UI, MinIO (dùng chung) |
| `argocd/applications/observability/` | kube-prometheus-stack, monitoring-config, ECK operator, elastic-stack, Fluent Bit, OTel Collector |
| `manifests/base/` | StorageClass `nfs-csi`, SA `jenkins-kaniko` |
| `manifests/ingress/` | Ingress HAProxy cho UI platform (argocd, harbor, jenkins, vault, keycloak, kafka-ui) |
| `manifests/rabbitmq/` | RabbitMQ standalone (credential qua Vault Agent) |
| `manifests/minio/` | Job tạo bucket + Ingress `npd-minio.co` / `npd-minio-console.co` |
| `manifests/monitoring/` | ServiceMonitor/PodMonitor, PrometheusRule, dashboard Grafana, Ingress grafana/prometheus/alertmanager |
| `manifests/elastic/` | Elasticsearch (1 node), Kibana, APM Server, Job `es-setup` (ILM, template, user grafana), Ingress kibana |
| `values/` | Values Postgres, Redis, Kong, MinIO, kube-prometheus-stack, Fluent Bit, OTel Collector |
| `f5-lb/` | NGINX Plus f5-lb: TLS + proxy tới HAProxy ingress |
| `scripts/vault-setup-k8s-auth.sh` | KV v2, auth kubernetes, policy + role cho injector |
| `scripts/keycloak-sso-setup.sh` | Realm `platform`, client argocd/jenkins/harbor/grafana, ghi secret vào Vault |
| `scripts/coredns-npd-hosts.sh` | Block `hosts` CoreDNS cho domain `npd-*.co` (pod gọi Keycloak/MinIO qua domain) |
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
