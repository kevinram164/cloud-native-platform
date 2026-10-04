# Triển khai platform trên Kubernetes (`dev-k8s`)

Cụm kubeadm tại lab NPD, thay cho cụm OpenShift `ocp01` đã gỡ. Manifest môi trường: [environments/dev-k8s/](./environments/dev-k8s/).

Repo `cloud-native-platform` chỉ chứa **platform** (Jenkins, Harbor, Vault, Keycloak, monitoring Prometheus/Grafana/Alertmanager, logging + tracing ELK/APM/OTel) và **infra dùng chung** (Postgres, Redis, RabbitMQ, Kong, Kafka, MinIO). Ứng dụng nằm ở repo riêng, ví dụ banking: `banking-demo@dev-k8s`, thư mục `deploy/dev-k8s/`.

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
| `npd-argocd.co` | `argocd/argocd-server:80` | platform |
| `npd-harbor.co` | `platform/harbor:80` | platform |
| `npd-jenkins.co` | `platform/jenkins:8080` | platform |
| `npd-vault.co` | `vault/vault:8200` | platform |
| `npd-kafka-ui.co` | `kafka/kafka-ui:80` | platform |
| `npd-keycloak.co` | `keycloak/keycloak:8080` | platform |
| `npd-minio.co` | `minio/minio:9000` (S3 API) | platform |
| `npd-minio-console.co` | `minio/minio:9001` (console) | platform |
| `npd-grafana.co` | `monitoring/kube-prometheus-stack-grafana:80` | platform |
| `npd-prometheus.co` | `monitoring/kube-prometheus-stack-prometheus:9090` | platform |
| `npd-alertmanager.co` | `monitoring/kube-prometheus-stack-alertmanager:9093` | platform |
| `npd-kibana.co` | `observability/kb-kb-http:5601` | platform |
| `npd-banking.co` | Ingress `npd-banking` (frontend + Kong) | banking-demo |

NGINX Plus trên f5-lb cần upstream `10.100.1.46:80` cho các server name trên, kèm `proxy_set_header Host $host` và `X-Forwarded-Proto https`. Với Harbor, đặt `client_max_body_size 0`. Mỗi domain có một file trong `environments/dev-k8s/f5-lb/conf.d/`; cert `/etc/nginx/certs/tls.crt` phải có SAN cho domain mới (hoặc wildcard).

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

`server.insecure=true` vì TLS đã kết thúc ở f5-lb. Ingress `npd-argocd.co` do Application `platform-ingress` tạo ở bước sau. Trước đó có thể dùng `kubectl port-forward svc/argocd-server -n argocd 8080:80`.

Repo GitHub public nên ArgoCD không cần credential.

## 4. Triển khai theo giai đoạn

Chạy từ root repo `cloud-native-platform`:

```bash
# Giai đoạn 1 — AppProject platform + NFS CSI, StorageClass, Vault (+ injector), Harbor, Jenkins, Ingress
bash phase9-gitops-platform/environments/dev-k8s/apply-argocd.sh

# Giai đoạn 2 — init/unseal + cấu hình Vault (mục 5). Jenkins và RabbitMQ chờ bước này.

# Giai đoạn 3 — infra (Postgres, Redis, RabbitMQ, Kong, Strimzi Kafka, Kafka UI, MinIO)
STAGE=infra bash phase9-gitops-platform/environments/dev-k8s/apply-argocd.sh

# Giai đoạn 4 — observability: kube-prometheus-stack + monitoring-config (ns monitoring),
# ECK operator (ns elastic-system), Elasticsearch/Kibana/APM + Fluent Bit + OTel Collector (ns observability)
STAGE=observability bash phase9-gitops-platform/environments/dev-k8s/apply-argocd.sh
```

Sau đó triển khai app từ repo của app (mục 9). SSO Keycloak: mục 6. Monitoring và logging: mục 7.

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
| `minio/minio` | 1001:1001 | MinIO dùng chung; giữ root user/password cũ (IAM mã hoá bằng root credential) |
| `observability/*`, `logging/*` | — | Coroot/OpenSearch cũ, không dùng lại: dời sang `_old` (`--fresh-observability`), ES/Prometheus tạo PVC mới |

**Bước 1 — trên NFS server, trước khi sync stage platform:**

```bash
scp phase9-gitops-platform/environments/dev-k8s/scripts/nfs-reuse-prepare.sh root@10.100.1.180:/root/
ssh root@10.100.1.180
bash nfs-reuse-prepare.sh                                   # kiểm tra: folder còn/mất, owner, cluster.id Kafka
bash nfs-reuse-prepare.sh --backup /root/nfs-backup         # tar vault + 2 DB
bash nfs-reuse-prepare.sh --apply --fresh-observability     # chown + dời observability, logging sang _old
```

Export `/shares/registry` nên có `no_root_squash` (kubelet đổi group theo `fsGroup`); script in ra `exportfs -v` để kiểm tra.

**Bước 2 — Vault (data cũ):** không chạy `vault operator init`. Chỉ cần unseal bằng key cũ, rồi dùng root token cũ. KV `secret/` và các secret đã seed vẫn còn; kiểm tra lại giá trị (host Harbor `npd-harbor.co` trong `platform/harbor`, `platform/harbor-pull`). Chạy `vault-setup-k8s-auth.sh` để ghi lại auth kubernetes cho cụm mới (CA, host, role mới). Mất unseal key thì không mở được data: dời `vault/data-vault-0` đi và init mới.

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
| Jenkins controller | `jenkins` (platform) | `jenkins` | `platform/jenkins` {`admin_username`, `admin_password`}, `platform/keycloak-clients` {`jenkins`} | JCasC `${readFile:/vault/secrets/*}` (OIDC + escape hatch) |
| Keycloak | `keycloak` (keycloak), `keycloak-db-init` (postgres) | `keycloak` | `platform/keycloak` {`admin_password`, `db_password`} | `KC_*_PASSWORD_FILE=/vault/secrets/*` |
| Jenkins agent (Kaniko) | `jenkins-kaniko` (platform) | `jenkins-kaniko` | `platform/harbor`, `platform/github` | Pipeline gọi Vault API trực tiếp |
| RabbitMQ | `rabbitmq` (rabbit) | `rabbitmq` | `rabbitmq/admin` {`username`, `password`} | `. /vault/secrets/env` → `RABBITMQ_DEFAULT_USER/PASS` |
| Banking services | `auth-service`, `account-service`, `transfer-service`, `notification-service`, `api-producer` (npd-banking) | `banking-app` | `banking/db` {`DATABASE_URL`, `REDIS_URL`}, `banking/rabbitmq` {`RABBITMQ_URL`} | `. /vault/secrets/env` |
| MinIO + Job tạo bucket | `minio`, `minio-bucket-init` (minio) | `minio` | `platform/minio` {`root_user`, `root_password`} | `MINIO_ROOT_*_FILE=/opt/bitnami/minio/secrets/*`; Job `. /vault/secrets/root` |
| Grafana | `kube-prometheus-stack-grafana` (monitoring) | `grafana` | `platform/grafana` {`admin_password`}, `platform/keycloak-clients` {`grafana`}, `platform/elastic` {`grafana_password`} | `GF_SECURITY_ADMIN_PASSWORD__FILE`, `$__file{/vault/secrets/*}` trong grafana.ini / datasource |
| Alertmanager | `kube-prometheus-stack-alertmanager` (monitoring) | `alertmanager` | `platform/alertmanager-telegram` {`bot_token`} | `telegram_configs.bot_token_file` |
| Job `es-setup` | `es-setup` (observability) | `elastic-setup` | `platform/elastic` {`grafana_password`} | Tạo user ES `grafana` (Grafana datasource) |

### Init, unseal, seed

```bash
kubectl exec -n vault vault-0 -- vault operator init
kubectl exec -n vault vault-0 -- vault operator unseal   # 3 lần, lặp lại sau mỗi lần pod restart
export VAULT_TOKEN=<root-token>
alias v='kubectl exec -i -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN vault'

v secrets enable -path=secret kv-v2
v kv put secret/platform/jenkins admin_username=admin admin_password='<pass>'
v kv put secret/platform/keycloak admin_password='<pass>' db_password='<pass>'
v kv put secret/platform/harbor registry=npd-harbor.co username='robot$banking-demo+ci' password='<token>'
v kv put secret/platform/harbor-pull registry=npd-harbor.co username='robot$banking-demo+k8s-pull' password='<token>'
v kv put secret/platform/github username=<user> pat='<pat>'
v kv put secret/rabbitmq/admin username=banking password='<pass>'
v kv put secret/banking/db \
  DATABASE_URL='postgresql://banking:<pass>@postgres-postgresql-primary.postgres.svc.cluster.local:5432/banking' \
  REDIS_URL='sentinel://:<pass-url-encoded>@redis.redis.svc.cluster.local:26379/0/mymaster'
v kv put secret/banking/rabbitmq RABBITMQ_URL='amqp://banking:<pass>@rabbitmq.rabbit.svc.cluster.local:5672/'
# MinIO dùng lại data OCP: bắt buộc giữ root cũ (minioadmin / mật khẩu cũ)
v kv put secret/platform/minio root_user=minioadmin root_password='<pass cũ>'
v kv put secret/platform/grafana admin_password='<pass>'
v kv put secret/platform/alertmanager-telegram bot_token='<token BotFather>'
v kv put secret/platform/elastic grafana_password='<pass>'
# platform/keycloak-clients (argocd, jenkins, harbor, grafana) do keycloak-sso-setup.sh ghi (mục 6)
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

containerd trên mọi node phải tin cert của `npd-harbor.co` (cert do f5-lb cấp). Với CA nội bộ:

```bash
mkdir -p /etc/containerd/certs.d/npd-harbor.co
cp npd-ca.crt /etc/containerd/certs.d/npd-harbor.co/ca.crt
cat > /etc/containerd/certs.d/npd-harbor.co/hosts.toml <<'EOF'
server = "https://npd-harbor.co"
[host."https://npd-harbor.co"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/npd-harbor.co/ca.crt"
EOF
# containerd config: [plugins."io.containerd.grpc.v1.cri".registry] config_path = "/etc/containerd/certs.d"
systemctl restart containerd
```

Node cũng phải phân giải được `npd-harbor.co` về `10.100.1.100`.

## 6. SSO Keycloak (ArgoCD, Harbor, Jenkins, Grafana)

Keycloak `https://npd-keycloak.co` (Application `platform-keycloak`, ns `keycloak`) dùng database `keycloak` trên `postgres-ha`. Khi dùng lại NFS từ OCP, realm `platform`, client, user và group cũ vẫn còn; script bên dưới chỉ cập nhật redirect URI sang domain mới. Mọi secret đi qua Vault.

| Client | Redirect URI | Cách nối |
|--------|--------------|----------|
| `argocd` | `https://npd-argocd.co/auth/callback` | `argocd-oidc-keycloak.sh` patch `argocd-cm`, `argocd-secret`, `argocd-rbac-cm` |
| `jenkins` | `https://npd-jenkins.co/securityRealm/finishLogin` | JCasC `securityRealm.oic`, secret qua Vault Agent |
| `harbor` | `https://npd-harbor.co/c/oidc/callback` | `harbor-oidc-keycloak.sh` gọi Harbor API (lưu trong DB Harbor) |
| `grafana` | `https://npd-grafana.co/login/generic_oauth` | `auth.generic_oauth` trong values kube-prometheus-stack, secret qua Vault Agent |

Lab: user thuộc group `platform-admin` là admin ở cả bốn hệ thống (Grafana: `Admin`, user khác `Viewer`). Backend ArgoCD/Harbor/Jenkins gọi Keycloak qua `https://npd-keycloak.co` với `insecure/skip verify` (cert f5-lb do CA nội bộ cấp).

```bash
S=phase9-gitops-platform/environments/dev-k8s/scripts
export VAULT_TOKEN=<token>

# 1. Pod phân giải được npd-*.co (bỏ qua nếu DNS nội bộ đã có bản ghi)
bash $S/coredns-npd-hosts.sh

# 2. Secret Keycloak + role Vault (DB cũ OCP: db_password=ChangeMe-Keycloak-DB, admin master cũ giữ nguyên)
v kv put secret/platform/keycloak admin_password='<pass>' db_password='<pass>'
bash $S/vault-setup-k8s-auth.sh

# 3. Push repo → ArgoCD sync platform-keycloak (PreSync Job keycloak-db-init trên ns postgres)
kubectl -n keycloak rollout status sts/keycloak

# 4. Realm/client/group → client secret vào Vault secret/platform/keycloak-clients
KC_ADMIN_PASSWORD='<admin master>' SSO_USER=<user> SSO_PASSWORD='<pass>' bash $S/keycloak-sso-setup.sh

# 5. Nối từng hệ thống
bash $S/argocd-oidc-keycloak.sh
HARBOR_ADMIN_PASSWORD='<admin harbor>' bash $S/harbor-oidc-keycloak.sh
kubectl -n platform delete pod jenkins-0     # Vault Agent render oidc-client-secret, JCasC bật OIDC
kubectl -n monitoring rollout restart deploy kube-prometheus-stack-grafana   # nhận secret client grafana
```

Jenkins: nếu Keycloak lỗi, đăng nhập bằng escape hatch (`admin` + `secret/platform/jenkins.admin_password`). Harbor: admin local ở `https://npd-harbor.co/account/sign-in`. ArgoCD: user `admin` local vẫn bật.

f5-lb: thêm `f5-lb/conf.d/70-npd-keycloak.conf`.

## 7. Monitoring và Logging

```text
Metrics:  ServiceMonitor/PodMonitor ──► Prometheus ──► PrometheusRule ──► Alertmanager ──► Telegram
                                           └──► Grafana (dashboard NPD, datasource ES logs + APM)
Logs:     container stdout ──► Fluent Bit (DaemonSet) ──► Elasticsearch logs-{bank,shop,movie,infra}-YYYY.MM.DD ──► Kibana
Traces:   app (OTLP) ──► OTel Collector ──► APM Server ──► Elasticsearch traces-apm* ──► Kibana APM
```

| Application | Namespace | Nội dung |
|-------------|-----------|----------|
| `observability-kube-prometheus-stack` | monitoring | Prometheus (7 ngày, 20Gi), Alertmanager, Grafana (SSO Keycloak), node-exporter, kube-state-metrics |
| `observability-monitoring-config` | monitoring | `manifests/monitoring`: ServiceMonitor/PodMonitor (banking, shop, postgres, redis, kong, rabbitmq, kafka, minio), PrometheusRule, dashboard, Ingress |
| `observability-eck-operator` | elastic-system | ECK operator 3.5 |
| `observability-elastic-stack` | observability | `manifests/elastic`: Elasticsearch 8.19 (1 node, 50Gi), Kibana, APM Server, Job `es-setup`, Ingress Kibana |
| `observability-fluent-bit` | observability | DaemonSet, đọc `/var/log/containers`, lọc theo namespace |
| `observability-otel-collector` | observability | OTLP `opentelemetry-collector.observability:4317/4318` → APM Server |

Prometheus chọn mọi ServiceMonitor/PodMonitor/PrometheusRule trong cụm (không cần label `release`). App ở repo khác cứ tạo ServiceMonitor trong namespace của mình. Dashboard: ConfigMap có label `grafana_dashboard: "1"` ở bất kỳ namespace nào (annotation `grafana_folder` để chọn folder).

**Trước khi sync stage observability:** seed `platform/grafana`, `platform/alertmanager-telegram`, `platform/elastic` (mục 5), chạy lại `vault-setup-k8s-auth.sh`, và chạy `keycloak-sso-setup.sh` để có secret client `grafana`. Thiếu secret thì pod Grafana/Alertmanager kẹt ở `vault-agent-init`.

### Alert Telegram

Alertmanager gửi về chat `-1004489182185` (sửa `chat_id` trong `values/values-kube-prometheus-stack.yaml`). Route: `team=banking|shop|movie` gửi nhanh (group_wait 10s, lặp 30m); còn lại group theo namespace + alertname, lặp 4h; `severity=info|none` và `Watchdog` bỏ qua. Bot phải được thêm vào group chat.

```bash
kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert add NPDTestTelegram severity=warning namespace=test \
  --annotation=summary="Test Telegram từ Alertmanager" --alertmanager.url=http://localhost:9093
```

Không nhận được tin: `kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager | grep -i telegram` (token sai → 401, bot chưa ở trong group → 400 chat not found).

### Kibana

Đăng nhập `https://npd-kibana.co` bằng user `elastic` (Basic license không có SSO):

```bash
kubectl -n observability get secret es-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d; echo
```

- Data view (Stack Management → Data Views): `logs-bank-*`, `logs-shop-*`, `logs-movie-*`, `logs-infra-*`, time field `@timestamp`.
- Trace: Observability → APM (service name lấy từ `OTEL_SERVICE_NAME` của app).
- Job `es-setup` (mỗi lần sync + CronJob 03:00) tạo ILM `logs-retention-7d` (xoá index log sau 7 ngày), index template `npd-logs` (replicas 0 vì chỉ có 1 node), replicas 0 cho data stream APM, role `grafana_reader` và user `grafana`. Data stream APM dùng ILM mặc định của Elastic.
- Log app JSON (bank/shop) được tách field (`event`, `outcome`, …). Thêm namespace thu log: sửa regex trong `values/values-fluent-bit.yaml`.

Grafana có sẵn datasource `Elasticsearch Logs` (`logs-*`) và `APM Traces` (`traces-apm*`), user ES `grafana` chỉ có quyền đọc.

### MinIO dùng chung

`infra-minio` (ns `minio`, 200Gi NFS) dùng lại data OCP. Job `minio-bucket-init` (PostSync) tạo bucket `movies`, `posters` (public download), `raw`, `backups`; thêm bucket thì sửa `manifests/minio/bucket-init.yaml`. App trong cụm dùng `http://minio.minio.svc.cluster.local:9000`; từ ngoài `https://npd-minio.co`. Nên tạo access key riêng cho từng app trong console thay vì dùng root.

### Control plane kubeadm

kube-scheduler, kube-controller-manager và etcd của kubeadm chỉ bind `127.0.0.1`, nên đã tắt scrape (và rule mặc định tương ứng) trong values. Muốn bật: sửa `/etc/kubernetes/manifests/*.yaml` trên master (`--bind-address=0.0.0.0`; etcd `--listen-metrics-urls=http://0.0.0.0:2381`), rồi bật `kubeScheduler`/`kubeControllerManager`/`kubeEtcd` trong `values-kube-prometheus-stack.yaml`.

### Dọn Coroot cũ

Application con bị xoá khỏi Git vẫn còn trên cụm (app-of-apps `prune: false`). Xoá kèm tài nguyên (CR trước, operator sau):

```bash
for app in observability-coroot-ce observability-coroot-operator; do
  kubectl -n argocd patch application "$app" --type merge \
    -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
  kubectl -n argocd delete application "$app" --wait=true
done
kubectl get crd -o name | grep -i coroot | xargs -r kubectl delete
kubectl -n observability get pvc        # xoá PVC Coroot còn sót (Retain → dọn folder trên NFS)
```

## 8. CI (Jenkins → Harbor → GitOps)

- Harbor: tạo project `banking-demo`, robot `ci` (push) lưu vào `platform/harbor`, robot `k8s-pull` (pull) lưu vào `platform/harbor-pull`.
- Jenkins: Multibranch Pipeline repo `banking-demo`, nhánh `dev-k8s`, Script Path `Jenkinsfile`.
- Pipeline build bằng Kaniko, push `npd-harbor.co/banking-demo/<svc>`, rồi bump `tag` trong `deploy/dev-k8s/values/values-images.yaml` của chính repo `banking-demo`. ArgoCD project `banking` sync.

## 9. Triển khai banking (repo `banking-demo`)

Điều kiện: infra Healthy, Vault đã seed `banking/*` và chạy `vault-setup-k8s-auth.sh`, Secret `harbor-pull-creds` đã có trong `npd-banking`.

```bash
cd banking-demo   # nhánh dev-k8s
kubectl apply -f deploy/dev-k8s/argocd/appproject.yaml
kubectl apply -f deploy/dev-k8s/argocd/app-of-apps.yaml
```

Chi tiết: `banking-demo/deploy/dev-k8s/README.md`.

## 10. Kiểm tra

```bash
kubectl get applications -n argocd
kubectl get pods -n vault                      # vault-0 + vault-agent-injector
kubectl get ingress -A
kubectl get pvc -A
kubectl logs -n npd-banking deploy/auth-service -c vault-agent-init
curl -sI https://npd-banking.co
```

| Triệu chứng | Kiểm tra |
|-------------|----------|
| PVC Pending | `kubectl get pods -n kube-system -l app.kubernetes.io/name=csi-driver-nfs`, node có `nfs-common` |
| `Permission denied` trên volume cũ | `chown` theo bảng mục 4 |
| Ingress 404 | Header `Host` từ f5-lb; `kubectl get ingress -A`; class `haproxy` |
| Pod kẹt `Init:0/1` (`vault-agent-init`) | Vault sealed; role/SA/namespace sai; path chưa seed → log container `vault-agent-init` |
| Pod không có `vault-agent-init` | Injector chưa chạy (`kubectl get pods -n vault`), annotation sai, pod tạo trước khi injector sẵn sàng → restart pod |
| `/vault/secrets/env: not found` | Annotation template thiếu; kiểm tra `agent-inject-secret-env` |
| ImagePullBackOff | containerd trust `npd-harbor.co`, Secret `harbor-pull-creds` trong namespace của app |
| Jenkins không đăng nhập được | `kubectl exec -n platform jenkins-0 -c jenkins -- cat /vault/secrets/admin-user` |
| `platform-ingress` lỗi namespace | Bình thường đến khi infra tạo ns `kafka`, `keycloak` — app tự retry |
| App lỗi, refresh không sync lại (đang backoff retry) | ArgoCD UI: Terminate operation rồi Sync |
| Grafana/Alertmanager kẹt `Init` | Thiếu `platform/grafana`, `platform/keycloak-clients.grafana`, `platform/elastic`, `platform/alertmanager-telegram` hoặc chưa chạy lại `vault-setup-k8s-auth.sh` |
| Prometheus target down (`npd-prometheus.co/targets`) | Port name của Service khớp ServiceMonitor; MinIO: chart đặt sẵn `MINIO_PROMETHEUS_AUTH_TYPE=public` |
| Kibana không có log | `kubectl -n observability logs ds/fluent-bit`; `kubectl -n observability logs job/es-setup`; index phải là index thường, không phải data stream |
| Elasticsearch `yellow` | Index có replica > 0 trên 1 node → chạy lại `kubectl -n observability create job --from=cronjob/es-setup es-setup-manual` |
| APM không có trace | App gửi OTLP tới `opentelemetry-collector.observability:4317`; log collector có lỗi `401` → Secret `apm-apm-token` |
