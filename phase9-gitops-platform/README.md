# Phase 9 — GitOps Platform (`dev-k8s`)

Platform CI/CD và infra dùng chung trên cụm kubeadm NPD (Cilium, HAProxy ingress, NFS CSI).

**Hướng dẫn đầy đủ:** **[K8S-DEPLOY-GUIDE.md](./K8S-DEPLOY-GUIDE.md)**

## Thứ tự triển khai

| Giai đoạn | Nội dung | Repo |
|-----------|----------|------|
| 0 | ArgoCD (Helm) | — |
| 1 | Platform: NFS CSI, StorageClass, Vault + Agent Injector, Harbor, Jenkins, Ingress | cloud-native-platform |
| 2 | Vault: init/unseal, seed, `vault-setup-k8s-auth.sh` | cloud-native-platform |
| 3 | Infra: Postgres, Redis, RabbitMQ, Kong, Kafka | cloud-native-platform |
| 4 | Observability: Coroot, OTEL Collector | cloud-native-platform |
| 5 | CI: Jenkins → Harbor → bump tag trong repo app | app repo |
| 6 | App: AppProject + app-of-apps của app | app repo (`banking-demo/deploy/dev-k8s`) |

## Cấu trúc ArgoCD (`environments/dev-k8s`)

```
AppProject platform
platform-app-of-apps      → csi-driver-nfs, k8s-base, vault (+ injector), harbor, jenkins, platform-ingress
infra-app-of-apps         → postgres, redis, rabbitmq, kong, strimzi-operator, kafka, kafka-ui
observability-app-of-apps → coroot-operator, coroot-ce, opentelemetry-collector

AppProject banking (repo banking-demo)
banking-root-dev-k8s      → namespace, auth/account/transfer/notification/api-producer, shop-bridge, frontend, ingress
```

## Secret

Vault Agent Injector thay cho External Secrets Operator. Pod có annotation `vault.hashicorp.com/agent-inject` được thêm init container login bằng ServiceAccount và ghi secret vào `/vault/secrets/`. Role/policy: `environments/dev-k8s/scripts/vault-setup-k8s-auth.sh`.

## Thư mục khác

| Thư mục | Ghi chú |
|---------|---------|
| `harbor/`, `vault/`, `jenkins/`, `observability/`, `kafka/` | Tài liệu và values từng thành phần |
| `platform/keycloak`, `logging/`, `monitoring/` | Chưa bật trên dev-k8s |
| `environments/dev-ocp`, `gitops-platform/`, `OCP-*.md` | OpenShift cũ (cụm đã gỡ), chỉ tham khảo |
