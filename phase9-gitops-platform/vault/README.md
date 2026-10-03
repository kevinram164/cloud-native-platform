# Vault + Vault Agent Injector

Vault (ns `vault`, standalone, file storage trên `nfs-csi`) là nguồn secret duy nhất. Không dùng External Secrets Operator: workload nhận secret trực tiếp qua **Vault Agent Injector** (`injector.enabled: true` trong Application `platform-vault`).

## Cách hoạt động

```text
Pod có annotation vault.hashicorp.com/agent-inject: "true"
  └─► webhook vault-agent-injector thêm init container vault-agent-init
        └─► login auth/kubernetes bằng ServiceAccount token của pod (role)
              └─► đọc KV v2, render template → /vault/secrets/<tên>
                    └─► container chính đọc file hoặc `. /vault/secrets/env && exec <cmd>`
```

Annotation chuẩn trong repo:

```yaml
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/agent-init-first: "true"          # chạy trước các init container khác
vault.hashicorp.com/agent-pre-populate-only: "true"   # chỉ init, không sidecar
vault.hashicorp.com/role: "<role>"
vault.hashicorp.com/agent-inject-secret-env: "secret/data/<path>"
vault.hashicorp.com/agent-inject-template-env: |
  {{ with secret "secret/data/<path>" }}
  export KEY='{{ .Data.data.KEY }}'
  {{ end }}
```

Với KV v2, path trong annotation có `data/` (`secret/data/banking/db`); lệnh CLI `vault kv` thì không (`secret/banking/db`).

Không có sidecar nên secret chỉ được đọc lúc pod khởi động. Sau `vault kv put`/`patch`, restart workload (`kubectl rollout restart`).

Nếu chart chạy `tpl` trên `podAnnotations` (ví dụ chart Jenkins), bọc template Vault trong `` {{` ... `}} `` để Helm giữ nguyên.

## Path, role và workload

| Vault path (KV v2) | Field | Role | Workload |
|--------------------|-------|------|----------|
| `secret/platform/jenkins` | `admin_username`, `admin_password` | `jenkins` | Jenkins controller → JCasC `${readFile:/vault/secrets/admin-*}` |
| `secret/platform/harbor` | `registry`, `username`, `password` | `jenkins-kaniko` | Pipeline Kaniko push (đọc qua Vault API) |
| `secret/platform/github` | `username`, `pat` | `jenkins-kaniko` | Pipeline commit bump tag |
| `secret/platform/harbor-pull` | `registry`, `username`, `password` | — | `create-harbor-pull-secret.sh` → Secret `harbor-pull-creds` |
| `secret/rabbitmq/admin` | `username`, `password` | `rabbitmq` | RabbitMQ (`RABBITMQ_DEFAULT_USER/PASS`) |
| `secret/banking/db` | `DATABASE_URL`, `REDIS_URL` | `banking-app` | auth, account, transfer, notification, api-producer |
| `secret/banking/rabbitmq` | `RABBITMQ_URL` | `banking-app` | như trên |

Policy và role: [environments/dev-k8s/scripts/vault-setup-k8s-auth.sh](../environments/dev-k8s/scripts/vault-setup-k8s-auth.sh).

`harbor-pull` là ngoại lệ: kubelet pull image trước khi bất kỳ container nào chạy, nên imagePullSecrets phải là Secret K8s. Vault giữ credential gốc, script tạo Secret.

## Init, unseal

```bash
kubectl exec -n vault vault-0 -- vault operator init      # lưu 5 unseal key + root token
kubectl exec -n vault vault-0 -- vault operator unseal    # 3 lần; lặp lại sau mỗi lần pod restart
```

## CLI

```bash
export VAULT_TOKEN=<token>
alias v='kubectl exec -i -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN vault'

v secrets list                       # cần secret/ type kv version 2
v secrets enable -path=secret kv-v2  # nếu chưa có
v kv put secret/banking/db DATABASE_URL='...' REDIS_URL='...'
v kv get -field=DATABASE_URL secret/banking/db
v kv patch secret/banking/db REDIS_URL='...'
v kv list secret/banking/
v kv metadata get secret/banking/db
```

Lệnh seed đầy đủ: [K8S-DEPLOY-GUIDE.md](../K8S-DEPLOY-GUIDE.md) mục 5. Giá trị được render vào `export KEY='...'`, nên không dùng dấu nháy đơn `'` trong secret.

## Xử lý lỗi

| Triệu chứng | Kiểm tra |
|-------------|----------|
| Pod kẹt `Init:0/1` | `kubectl logs <pod> -c vault-agent-init`: Vault sealed, `permission denied` (role/policy), `service account name not authorized` (SA/namespace không khớp role) |
| Pod không có `vault-agent-init` | `kubectl get pods -n vault` (injector Running?), `kubectl get mutatingwebhookconfiguration vault-agent-injector-cfg`; pod tạo trước injector → restart |
| `no secret exists at secret/data/...` | Chưa seed path, hoặc thiếu `data/` trong annotation |
| `/vault/secrets/env: not found` | Thiếu annotation `agent-inject-secret-env` / `agent-inject-template-env` |

Test login từ một SA:

```bash
kubectl run vault-test --rm -i --restart=Never -n npd-banking --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"auth-service"}}' -- \
  sh -c 'curl -s -X POST -d "{\"jwt\":\"$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\",\"role\":\"banking-app\"}" \
    http://vault.vault.svc.cluster.local:8200/v1/auth/kubernetes/login'
```
