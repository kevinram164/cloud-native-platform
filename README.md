# cloud-native-platform

GitOps platform cho cụm NPD: Argo CD, Harbor, Jenkins, Vault, External Secrets, NFS CSI, Postgres, Redis, RabbitMQ, Kong, Kafka, Keycloak, observability, logging, Istio ambient.

Mã nguồn ứng dụng nằm ở repo riêng. Repo này chỉ giữ desired state của nền tảng và Application ArgoCD.

| Repo | Giữ lại |
|------|---------|
| [banking-demo](https://github.com/kevinram164/banking-demo) | Chart và source banking (`phase2-helm-chart`, `phase5`, `phase8`) |
| [movie-web](https://github.com/kevinram164/movie-web) | App CineHome, `deploy/argocd` |
| [npd-shop](https://github.com/kevinram164/npd-shop) | App shop |
| [jenkins-shared-library](https://github.com/kevinram164/jenkins-shared-library) | Shared library Jenkins load lúc chạy |
| [Open-Source-AIOps-Platform](https://github.com/kevinram164/Open-Source-AIOps-Platform) | Sản phẩm AIOps, không phải addon cụm |

## Bắt đầu

Hướng dẫn triển khai: [phase9-gitops-platform/OCP-DEPLOY-GUIDE.md](phase9-gitops-platform/OCP-DEPLOY-GUIDE.md).

```bash
# từ root repo này
oc apply -f phase9-gitops-platform/environments/dev-ocp/appproject.yaml -n argocd
oc apply -f phase9-gitops-platform/environments/dev-ocp/argocd/applications/platform-app-of-apps.yaml -n argocd
```

AppProject `banking-platform` được phép đọc cả repo này và `banking-demo`. Chart banking vẫn ở `banking-demo` nhánh `dev-ocp`. Values image (`phase9-gitops-platform/gitops/values-images.yaml`) ở nhánh `main` của repo này. Jenkins clone repo này khi bump tag.

CineHome AppProject: `phase9-gitops-platform/environments/dev-ocp/appproject-cinehome.yaml`. Manifest app vẫn ở `movie-web`.

## Không đưa vào repo này

- `k8s-lab` — bài lab GitLab/Kubernetes, không phải platform đang chạy.
- `F5-LB` — binary NGINX Plus và key, không commit.
- `Open-Source-AIOps-Platform` — ứng dụng AIOps.
- `crowdsec`, `fineract` — upstream.
