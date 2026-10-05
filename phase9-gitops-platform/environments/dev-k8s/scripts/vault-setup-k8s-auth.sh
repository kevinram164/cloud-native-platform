#!/usr/bin/env bash
# Cấu hình Vault cho dev-k8s: KV v2 + Kubernetes auth + policy/role cho Vault Agent Injector.
# Không dùng ESO — workload tự login bằng ServiceAccount token qua agent sidecar/init.
#
#   export VAULT_TOKEN=<root hoặc token có quyền sys/auth, sys/policy>
#   bash phase9-gitops-platform/environments/dev-k8s/scripts/vault-setup-k8s-auth.sh
#
# Role                SA (namespace)                                      Đọc
# jenkins-kaniko      jenkins-kaniko (platform)                           platform/harbor, platform/github (+ cinehome, aiops)
# jenkins             jenkins (platform)                                  platform/jenkins, platform/keycloak-clients
# keycloak            keycloak (keycloak), keycloak-db-init (postgres)     platform/keycloak
# rabbitmq            rabbitmq (rabbit)                                   rabbitmq/admin
# banking-app         auth/account/transfer/notification/api-producer     banking/db, banking/rabbitmq
#                     (npd-banking)
# minio               minio, minio-bucket-init (minio)                    platform/minio
# grafana             kube-prometheus-stack-grafana (monitoring)          platform/grafana, platform/keycloak-clients, platform/elastic
# alertmanager        kube-prometheus-stack-alertmanager,                 platform/alertmanager-telegram
#                     npd-status-digest (monitoring)
# elastic-setup       es-setup (observability)                            platform/elastic
set -euo pipefail

: "${VAULT_TOKEN:?export VAULT_TOKEN trước khi chạy}"
VAULT_NS="${VAULT_NS:-vault}"
BANKING_NS="${BANKING_NS:-npd-banking}"
BANKING_SAS="${BANKING_SAS:-auth-service,account-service,transfer-service,notification-service,api-producer}"

vexec() {
  kubectl exec -i -n "${VAULT_NS}" vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN}" sh -c "$1"
}

policy() {
  echo "==> policy $1"
  kubectl exec -i -n "${VAULT_NS}" vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN}" \
    vault policy write "$1" -
}

role() {
  echo "==> role $1 ← $2 @ $3"
  vexec "vault write auth/kubernetes/role/$1 \
    bound_service_account_names=$2 \
    bound_service_account_namespaces=$3 \
    policies=$4 ttl=1h"
}

echo "==> KV v2 tại secret/"
vexec "vault secrets list -format=json | grep -q '\"secret/\"' || vault secrets enable -path=secret kv-v2"

echo "==> Kubernetes auth (Vault dùng SA token + CA của chính pod, chart bật authDelegator)"
vexec "vault auth list -format=json | grep -q '\"kubernetes/\"' || vault auth enable kubernetes"
vexec "vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443"

policy jenkins-kaniko <<'EOF'
path "secret/data/platform/harbor" { capabilities = ["read"] }
path "secret/data/platform/github" { capabilities = ["read"] }
path "secret/data/cinehome/harbor" { capabilities = ["read"] }
path "secret/data/cinehome/harbor-pull" { capabilities = ["read"] }
path "secret/metadata/cinehome/*" { capabilities = ["read", "list"] }
path "secret/data/aiops/harbor" { capabilities = ["read"] }
path "secret/metadata/aiops/*" { capabilities = ["read", "list"] }
EOF

policy jenkins <<'EOF'
path "secret/data/platform/jenkins" { capabilities = ["read"] }
path "secret/data/platform/keycloak-clients" { capabilities = ["read"] }
EOF

policy keycloak <<'EOF'
path "secret/data/platform/keycloak" { capabilities = ["read"] }
EOF

policy rabbitmq <<'EOF'
path "secret/data/rabbitmq/admin" { capabilities = ["read"] }
EOF

policy banking-app <<'EOF'
path "secret/data/banking/db" { capabilities = ["read"] }
path "secret/data/banking/rabbitmq" { capabilities = ["read"] }
EOF

policy minio <<'EOF'
path "secret/data/platform/minio" { capabilities = ["read"] }
EOF

policy grafana <<'EOF'
path "secret/data/platform/grafana" { capabilities = ["read"] }
path "secret/data/platform/keycloak-clients" { capabilities = ["read"] }
path "secret/data/platform/elastic" { capabilities = ["read"] }
EOF

policy alertmanager <<'EOF'
path "secret/data/platform/alertmanager-telegram" { capabilities = ["read"] }
EOF

policy elastic-setup <<'EOF'
path "secret/data/platform/elastic" { capabilities = ["read"] }
EOF

role jenkins-kaniko jenkins-kaniko platform jenkins-kaniko
role jenkins jenkins platform jenkins
role keycloak keycloak,keycloak-db-init keycloak,postgres keycloak
role rabbitmq rabbitmq rabbit rabbitmq
role banking-app "${BANKING_SAS}" "${BANKING_NS}" banking-app
role minio minio,minio-bucket-init minio minio
role grafana kube-prometheus-stack-grafana monitoring grafana
role alertmanager kube-prometheus-stack-alertmanager,npd-status-digest monitoring alertmanager
role elastic-setup es-setup observability elastic-setup

echo "==> Kiểm tra secret đã seed"
for p in platform/harbor platform/harbor-pull platform/github platform/jenkins platform/keycloak platform/keycloak-clients \
         platform/minio platform/grafana platform/alertmanager-telegram platform/elastic \
         rabbitmq/admin banking/db banking/rabbitmq; do
  vexec "vault kv get secret/$p >/dev/null 2>&1" && echo "OK      secret/$p" || echo "MISSING secret/$p"
done
