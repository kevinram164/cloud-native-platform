# cloud-native-platform

GitOps platform cho cụm NPD (kubeadm + Cilium): Argo CD, Harbor, Jenkins, Vault (Agent Injector), NFS CSI, observability (Coroot + OTEL), và infra dùng chung (Postgres, Redis, RabbitMQ, Kong, Kafka). Keycloak, logging, monitoring sẽ bật sau.

Repo này chỉ giữ desired state của nền tảng. Ứng dụng (chart, values image, Application ArgoCD) nằm ở repo của từng app.

- Không dùng service mesh (Istio, Linkerd): Cilium lo CNI và network policy.
- Không dùng External Secrets Operator: workload nhận secret trực tiếp từ Vault qua Vault Agent Injector.

| Repo | Giữ lại |
|------|---------|
| [banking-demo](https://github.com/kevinram164/banking-demo) | Source, chart, `deploy/dev-k8s` (AppProject `banking`, Application, values image) |
| [movie-web](https://github.com/kevinram164/movie-web) | App CineHome, `deploy/argocd` |
| [npd-shop](https://github.com/kevinram164/npd-shop) | App shop |
| [jenkins-shared-library](https://github.com/kevinram164/jenkins-shared-library) | Shared library Jenkins load lúc chạy |
| [Open-Source-AIOps-Platform](https://github.com/kevinram164/Open-Source-AIOps-Platform) | Sản phẩm AIOps, không phải addon cụm |

## Bắt đầu

Hướng dẫn triển khai: [phase9-gitops-platform/K8S-DEPLOY-GUIDE.md](phase9-gitops-platform/K8S-DEPLOY-GUIDE.md).

```bash
# từ root repo này
bash phase9-gitops-platform/environments/dev-k8s/apply-argocd.sh                      # platform
STAGE=infra bash phase9-gitops-platform/environments/dev-k8s/apply-argocd.sh          # infra
STAGE=observability bash phase9-gitops-platform/environments/dev-k8s/apply-argocd.sh  # observability
```

`environments/dev-ocp`, `gitops-platform/` và `OCP-*.md` là bản OpenShift cũ (cụm đã gỡ), chỉ giữ để tham khảo. Phần banking, ESO, Istio, Linkerd đã bị xóa khỏi bản này nên nó không còn deploy được.

## Không đưa vào repo này

- Ứng dụng và values image của ứng dụng.
- `k8s-lab` — bài lab GitLab/Kubernetes, không phải platform đang chạy.
- `F5-LB` — binary NGINX Plus và key, không commit.
- `Open-Source-AIOps-Platform` — ứng dụng AIOps.
- `crowdsec`, `fineract` — upstream.
