# Triển khai platform trên Kubernetes (`dev-k8s`)

Cụm kubeadm tại lab NPD, thay cho cụm OpenShift `ocp01` đã gỡ. Manifest môi trường: [environments/dev-k8s/](./environments/dev-k8s/).

Repo `cloud-native-platform` chỉ chứa **platform** (Jenkins, Harbor, Vault, observability, sau này Keycloak, logging, monitoring) và **infra dùng chung** (Postgres, Redis, RabbitMQ, Kong, Kafka). Ứng dụng nằm ở repo riêng, ví dụ banking: `banking-demo@dev-k8s`, thư mục `deploy/dev-k8s/`.

Điểm chính của bản này:

- Không dùng service mesh (Istio, Linkerd). Cilium lo CNI và network policy.
- Không dùng External Secrets Operator. Secret đi thẳng từ Vault vào pod qua **Vault Agent Injector**.

## 1. Hạ tầng

| Vai trò | Host | IP |
|---------|------|----|
| Load balancer (NGINX Plus, kết thúc TLS) | f5-lb | 10.100.1.100 |
| Control plane | npd-master | 10.100.1.110 |
| Worker | npd-worker01–04 | 10.100.1.121–124 |
| Ingress node (HAProxy ingress, hostNetwork) | npd-route | 10.100.1.46 |
| NFS | storage | 10.100.1.180:/shares/registry |

Đã có sẵn trên cụm: Cilium, metrics-server, HAProxy ingress (`haproxy.org`, IngressClass `haproxy`).

```text
Client ──HTTPS──► f5-lb 10.100.1.100 ──HTTP──► npd-route 10.100.1.46 (HAProxy ingress)
                                                   └─► Service trong cụm
```

DNS (hoặc `hosts` trên máy client) trỏ các tên sau về `10.100.1.100`:

| Tên | Đích trong cụm | Repo |
|-----|----------------|------|
| `argocd-npd.co` | `argocd/argocd-server:80` | platform |
| `harbor-npd.co` | `platform/harbor:80` | platform |
| `jenkins-npd.co` | `platform/jenkins:8080` | platform |
| `vault-npd.co` | `vault/vault:8200` | platform |
| `coroot-npd.co` | `observability/coroot-coroot:8080` | platform |
| `kafka-ui-npd.co` | `kafka/kafka-ui:80` | platform |
| `banking-npd.co` | Ingress `npd-banking` (frontend + Kong) | banking-demo |

NGINX Plus trên f5-lb cần upstream `10.100.1.46:80` cho các server name trên, kèm `proxy_set_header Host $host` và `X-Forwarded-Proto https`. Với Harbor, đặt `client_max_body_size 0`.

## 2. Cấu trúc GitOps

| Repo | Nhánh | AppProject | Nội dung |
|------|-------|------------|----------|
| `cloud-native-platform` | `main` | `platform` | `environments/dev-k8s/argocd/applications/{platform,infra,observability}` |
| `banking-demo` | `dev-k8s` | `banking` | `deploy/dev-k8s/argocd` (9 app), chart `phase2-helm-chart/banking-demo`, `deploy/dev-k8s/values/values-images.yaml` |

Các Application của `dev-k8s` nằm riêng, không dùng `gitops-platform/applications/*` (bản OpenShift cũ, chỉ giữ để tham khảo).

## 3. ArgoCD

```bash
kubectl create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd -n argocd \
  --set 'configs.params.server\.insecure=true'
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

`server.insecure=true` vì TLS đã kết thúc ở f5-lb. Ingress `argocd-npd.co` do Application `platform-ingress` tạo ở bước sau. Trước đó có thể dùng `kubectl port-forward svc/argocd-server -n argocd 8080:80`.

Repo GitHub public nên ArgoCD không cần credential.

## 4. Triển khai theo giai đoạn

Chạy từ root repo `cloud-native-platform`:

```bash
# Giai đoạn 1 — AppProject platform + NFS CSI, StorageClass, Vault (+ injector), Harbor, Jenkins, Ingress
bash phase9-gitops-platform/environments/dev-k8s/apply-argocd.sh

# Giai đoạn 2 — init/unseal + cấu hình Vault (mục 5). Jenkins và RabbitMQ chờ bước này.

# Giai đoạn 3 — infra (Postgres, Redis, RabbitMQ, Kong, Strimzi Kafka, Kafka UI)
STAGE=infra bash phase9-gitops-platform/environments/dev-k8s/apply-argocd.sh

# Giai đoạn 4 — observability (Coroot, OTEL Collector)
STAGE=observability bash phase9-gitops-platform/environments/dev-k8s/apply-argocd.sh
```

Sau đó triển khai app từ repo của app (mục 7).

Kiểm tra storage trước giai đoạn 3:

```bash
kubectl get sc nfs-csi
kubectl create ns nfs-test
kubectl apply -f phase9-gitops-platform/environments/dev-k8s/manifests/test/test-pvc.yaml
kubectl get pvc -n nfs-test     # Bound
kubectl delete ns nfs-test      # reclaimPolicy Retain → xóa tay /shares/registry/nfs-test trên NFS
```

Mọi node (kể cả npd-route nếu có pod mount PVC) cần gói `nfs-common`.

### Dùng lại dữ liệu NFS từ cụm OCP

StorageClass `nfs-csi` mới giữ nguyên `server`, `share` và `subDir: ${namespace}/${pvc}`. Các app có PVC dùng cùng namespace, release name và chart version như bản OCP, nên PVC tạo ra trùng tên và csi-driver-nfs mount lại folder cũ `/shares/registry/<ns>/<pvc>` (thư mục đã có thì giữ nguyên nội dung). `reclaimPolicy` mới là `Retain`, nên xóa PVC không xóa data nữa.

SC cũ trên OCP dùng `reclaimPolicy: Delete`. Folder nào có PVC bị xóa trước khi gỡ cụm thì đã mất; script dưới sẽ báo `MISSING`.

| Folder (`/shares/registry/…`) | UID:GID trên K8s | Ghi chú |
|-------------------------------|------------------|---------|
| `vault/data-vault-0` | 100:1000 | Cần unseal key + root token của cụm cũ |
| `platform/jenkins` | 1000:1000 | Jobs, credentials, plugins |
| `platform/harbor-registry`, `platform/harbor-jobservice` | 10000:10000 | Image layers, job log |
| `platform/database-data-harbor-database-0` | 999:999 | Project, robot account, tag |
| `platform/data-harbor-redis-0` | 999:999 | Cache |
| `postgres/data-postgres-ha-postgresql-{primary,read}-0` | 1001:1001 | DB `banking`, `kong` |
| `redis/redis-data-redis-ha-node-*` | 1001:1001 | |
| `rabbit/rabbitmq-data` | 999:999 | User/vhost/queue cũ giữ nguyên |
| `kafka/data-0-npd-kafka-dual-role-{0,1,2}` | 1001:1001 | Cần patch `clusterId` (bên dưới) |
| `observability/*` | — | Telemetry cũ, nên cho Coroot chạy sạch (`--fresh-observability`) |

**Bước 1 — trên NFS server, trước khi sync stage platform:**

```bash
scp phase9-gitops-platform/environments/dev-k8s/scripts/nfs-reuse-prepare.sh root@10.100.1.180:/root/
ssh root@10.100.1.180
bash nfs-reuse-prepare.sh                                   # kiểm tra: folder còn/mất, owner, cluster.id Kafka
bash nfs-reuse-prepare.sh --backup /root/nfs-backup         # tar vault + 2 DB
bash nfs-reuse-prepare.sh --apply --fresh-observability     # chown + dời observability sang _old
```

Export `/shares/registry` nên có `no_root_squash` (kubelet đổi group theo `fsGroup`); script in ra `exportfs -v` để kiểm tra.

**Bước 2 — Vault (data cũ):** không chạy `vault operator init`. Chỉ cần unseal bằng key cũ, rồi dùng root token cũ. KV `secret/` và các secret đã seed vẫn còn; kiểm tra lại giá trị (host Harbor `harbor-npd.co` trong `platform/harbor`, `platform/harbor-pull`). Chạy `vault-setup-k8s-auth.sh` để ghi lại auth kubernetes cho cụm mới (CA, host, role mới). Mất unseal key thì không mở được data: dời `vault/data-vault-0` đi và init mới.

**Bước 3 — Kafka KRaft:** Strimzi sinh cluster ID mới cho Kafka CR mới, trong khi broker đọc `meta.properties` cũ → lỗi `Invalid cluster.id`. Application `infra-kafka` đang để `pauseReconciliation: true`, nên Strimzi tạo CR nhưng chưa dựng broker. Sau khi `infra-kafka` sync:

```bash
CLUSTER_ID=<cluster.id do nfs-reuse-prepare.sh in ra>
kubectl patch kafka npd-kafka -n kafka --subresource status --type merge \
  -p "{\"status\":{\"clusterId\":\"${CLUSTER_ID}\"}}"
kubectl get kafka npd-kafka -n kafka -o jsonpath='{.status.clusterId}'; echo
```

Rồi sửa `pauseReconciliation: false` trong `environments/dev-k8s/argocd/applications/infra/kafka.yaml`, commit, push. Strimzi dựng broker với data cũ (topic, offset giữ nguyên). CA và mật khẩu KafkaUser được sinh mới → copy lại Secret `npd-banking-kafka-user` và CA sang `npd-banking`. Nếu không còn folder Kafka cũ, đặt `false` ngay từ đầu.

**Còn lại:**

- **Harbor:** chart dùng `secretKey` mặc định cố định nên DB cũ đọc được; project, robot account, image giữ nguyên. Robot token cũ vẫn dùng được.
- **Jenkins:** JCasC ghi đè security realm (bỏ Keycloak OIDC cũ, dùng admin từ Vault). Jobs và credentials giữ nguyên.
- **Postgres / Redis / RabbitMQ:** cùng chart/image version với OCP nên mount thẳng. Mật khẩu là mật khẩu cũ trong data, không phải giá trị mới trong values/Vault (`RABBITMQ_DEFAULT_*` chỉ áp dụng khi data trống).

## 5. Vault và Vault Agent Injector

### Cách hoạt động

```text
Pod (annotation vault.hashicorp.com/agent-inject) ──► injector webhook thêm init container vault-agent-init
vault-agent-init ──login bằng SA token──► Vault auth/kubernetes (role) ──► đọc KV ──► ghi /vault/secrets/<file>
container chính ──► đọc file (JCasC readFile) hoặc `. /vault/secrets/env && exec <cmd>`
```

Các pod dùng `agent-pre-populate-only: "true"`: chỉ có init container, không có sidecar. Đổi secret trong Vault thì restart pod để nhận giá trị mới.

| Workload | SA (namespace) | Role | Secret Vault | Cách dùng |
|----------|----------------|------|--------------|-----------|
| Jenkins controller | `jenkins` (platform) | `jenkins` | `platform/jenkins` {`admin_username`, `admin_password`} | JCasC `${readFile:/vault/secrets/admin-*}` |
| Jenkins agent (Kaniko) | `jenkins-kaniko` (platform) | `jenkins-kaniko` | `platform/harbor`, `platform/github` | Pipeline gọi Vault API trực tiếp |
| RabbitMQ | `rabbitmq` (rabbit) | `rabbitmq` | `rabbitmq/admin` {`username`, `password`} | `. /vault/secrets/env` → `RABBITMQ_DEFAULT_USER/PASS` |
| Banking services | `auth-service`, `account-service`, `transfer-service`, `notification-service`, `api-producer` (npd-banking) | `banking-app` | `banking/db` {`DATABASE_URL`, `REDIS_URL`}, `banking/rabbitmq` {`RABBITMQ_URL`} | `. /vault/secrets/env` |

### Init, unseal, seed

```bash
kubectl exec -n vault vault-0 -- vault operator init
kubectl exec -n vault vault-0 -- vault operator unseal   # 3 lần, lặp lại sau mỗi lần pod restart
export VAULT_TOKEN=<root-token>
alias v='kubectl exec -i -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN vault'

v secrets enable -path=secret kv-v2
v kv put secret/platform/jenkins admin_username=admin admin_password='<pass>'
v kv put secret/platform/harbor registry=harbor-npd.co username='robot$banking-demo+ci' password='<token>'
v kv put secret/platform/harbor-pull registry=harbor-npd.co username='robot$banking-demo+k8s-pull' password='<token>'
v kv put secret/platform/github username=<user> pat='<pat>'
v kv put secret/rabbitmq/admin username=banking password='<pass>'
v kv put secret/banking/db \
  DATABASE_URL='postgresql://banking:<pass>@postgres-postgresql-primary.postgres.svc.cluster.local:5432/banking' \
  REDIS_URL='sentinel://:<pass-url-encoded>@redis.redis.svc.cluster.local:26379/0/mymaster'
v kv put secret/banking/rabbitmq RABBITMQ_URL='amqp://banking:<pass>@rabbitmq.rabbit.svc.cluster.local:5672/'
```

Giá trị được render vào `export KEY='...'`, nên secret không được chứa dấu nháy đơn `'`.

### Kubernetes auth, policy, role

```bash
VAULT_TOKEN=<token> bash phase9-gitops-platform/environments/dev-k8s/scripts/vault-setup-k8s-auth.sh
```

Script bật KV v2 và auth `kubernetes`, ghi policy và role theo bảng trên, rồi in danh sách secret còn thiếu.

### Image pull từ Harbor

Robot account Harbor (`robot$banking-demo+k8s-pull`, quyền pull) vẫn phải nằm trong Secret `kubernetes.io/dockerconfigjson`: kubelet pull image trước khi bất kỳ container nào chạy, kể cả Vault Agent. Vault là nơi lưu credential gốc; script tạo Secret từ Vault:

```bash
VAULT_TOKEN=<token> bash phase9-gitops-platform/environments/dev-k8s/scripts/create-harbor-pull-secret.sh
# NAMESPACES="npd-banking npd-shop" … cho nhiều namespace; chạy lại khi rotate token robot
```

### Registry trust trên node

containerd trên mọi node phải tin cert của `harbor-npd.co` (cert do f5-lb cấp). Với CA nội bộ:

```bash
mkdir -p /etc/containerd/certs.d/harbor-npd.co
cp npd-ca.crt /etc/containerd/certs.d/harbor-npd.co/ca.crt
cat > /etc/containerd/certs.d/harbor-npd.co/hosts.toml <<'EOF'
server = "https://harbor-npd.co"
[host."https://harbor-npd.co"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/harbor-npd.co/ca.crt"
EOF
# containerd config: [plugins."io.containerd.grpc.v1.cri".registry] config_path = "/etc/containerd/certs.d"
systemctl restart containerd
```

Node cũng phải phân giải được `harbor-npd.co` về `10.100.1.100`.

## 6. CI (Jenkins → Harbor → GitOps)

- Harbor: tạo project `banking-demo`, robot `ci` (push) lưu vào `platform/harbor`, robot `k8s-pull` (pull) lưu vào `platform/harbor-pull`.
- Jenkins: Multibranch Pipeline repo `banking-demo`, nhánh `dev-k8s`, Script Path `Jenkinsfile`.
- Pipeline build bằng Kaniko, push `harbor-npd.co/banking-demo/<svc>`, rồi bump `tag` trong `deploy/dev-k8s/values/values-images.yaml` của chính repo `banking-demo`. ArgoCD project `banking` sync.

## 7. Triển khai banking (repo `banking-demo`)

Điều kiện: infra Healthy, Vault đã seed `banking/*` và chạy `vault-setup-k8s-auth.sh`, Secret `harbor-pull-creds` đã có trong `npd-banking`.

```bash
cd banking-demo   # nhánh dev-k8s
kubectl apply -f deploy/dev-k8s/argocd/appproject.yaml
kubectl apply -f deploy/dev-k8s/argocd/app-of-apps.yaml
```

Chi tiết: `banking-demo/deploy/dev-k8s/README.md`.

## 8. Kiểm tra

```bash
kubectl get applications -n argocd
kubectl get pods -n vault                      # vault-0 + vault-agent-injector
kubectl get ingress -A
kubectl get pvc -A
kubectl logs -n npd-banking deploy/auth-service -c vault-agent-init
curl -sI https://banking-npd.co
```

| Triệu chứng | Kiểm tra |
|-------------|----------|
| PVC Pending | `kubectl get pods -n kube-system -l app.kubernetes.io/name=csi-driver-nfs`, node có `nfs-common` |
| `Permission denied` trên volume cũ | `chown` theo bảng mục 4 |
| Ingress 404 | Header `Host` từ f5-lb; `kubectl get ingress -A`; class `haproxy` |
| Pod kẹt `Init:0/1` (`vault-agent-init`) | Vault sealed; role/SA/namespace sai; path chưa seed → log container `vault-agent-init` |
| Pod không có `vault-agent-init` | Injector chưa chạy (`kubectl get pods -n vault`), annotation sai, pod tạo trước khi injector sẵn sàng → restart pod |
| `/vault/secrets/env: not found` | Annotation template thiếu; kiểm tra `agent-inject-secret-env` |
| ImagePullBackOff | containerd trust `harbor-npd.co`, Secret `harbor-pull-creds` trong namespace của app |
| Jenkins không đăng nhập được | `kubectl exec -n platform jenkins-0 -c jenkins -- cat /vault/secrets/admin-user` |
| `platform-ingress` lỗi namespace | Bình thường đến khi infra/observability tạo ns `kafka`, `observability` — app tự retry |
