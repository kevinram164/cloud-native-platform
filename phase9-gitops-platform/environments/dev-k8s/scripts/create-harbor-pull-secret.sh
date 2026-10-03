#!/usr/bin/env bash
# Tạo Secret harbor-pull-creds (kubernetes.io/dockerconfigjson) từ robot account Harbor lưu trong Vault.
# Kubelet pull image TRƯỚC khi container nào (kể cả Vault Agent) chạy, nên imagePullSecrets bắt buộc
# phải là Secret K8s — Vault Agent Injector không thay được. Chạy lại khi rotate robot token.
#
#   vault kv put secret/platform/harbor-pull registry=harbor-npd.co \
#     username='robot$banking-demo+k8s-pull' password='<token>'
#   export VAULT_TOKEN=...
#   bash create-harbor-pull-secret.sh                 # mặc định ns npd-banking
#   NAMESPACES="npd-banking npd-shop" bash create-harbor-pull-secret.sh
set -euo pipefail

: "${VAULT_TOKEN:?export VAULT_TOKEN trước khi chạy}"
VAULT_NS="${VAULT_NS:-vault}"
VAULT_PATH="${VAULT_PATH:-secret/platform/harbor-pull}"
SECRET_NAME="${SECRET_NAME:-harbor-pull-creds}"
NAMESPACES="${NAMESPACES:-npd-banking}"

field() {
  kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN}" \
    vault kv get -field="$1" "${VAULT_PATH}"
}

REGISTRY="$(field registry)"
USERNAME="$(field username)"
PASSWORD="$(field password)"

for ns in ${NAMESPACES}; do
  echo "==> ${ns}/${SECRET_NAME} (${REGISTRY})"
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry "${SECRET_NAME}" -n "${ns}" \
    --docker-server="${REGISTRY}" \
    --docker-username="${USERNAME}" \
    --docker-password="${PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -
done
