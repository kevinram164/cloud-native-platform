#!/usr/bin/env bash
# Harbor OIDC → Keycloak qua Harbor API (lưu trong DB Harbor → ArgoCD không revert như env CONFIG_OVERWRITE_JSON).
# Client secret đọc từ Vault. Group platform-admin = Harbor system admin.
# Robot account (CI push / k8s pull) không bị ảnh hưởng khi đổi auth_mode.
#
#   export VAULT_TOKEN=...
#   export HARBOR_ADMIN_PASSWORD=...     # admin local Harbor (DB cũ giữ mật khẩu cũ)
#   bash phase9-gitops-platform/environments/dev-k8s/scripts/harbor-oidc-keycloak.sh
set -euo pipefail

: "${VAULT_TOKEN:?export VAULT_TOKEN}"
: "${HARBOR_ADMIN_PASSWORD:?export HARBOR_ADMIN_PASSWORD}"
NS="${HARBOR_NAMESPACE:-platform}"
ISSUER="${KEYCLOAK_ISSUER:-https://npd-keycloak.co/realms/platform}"
ADMIN_GROUP="${ADMIN_GROUP:-platform-admin}"
PORT="${LOCAL_PORT:-18080}"

SECRET=$(kubectl exec -i -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN}" \
  vault kv get -field=harbor secret/platform/keycloak-clients)

kubectl -n "${NS}" port-forward svc/harbor "${PORT}:80" >/dev/null 2>&1 &
PF=$!
trap 'kill ${PF} 2>/dev/null || true' EXIT
sleep 3

API="http://127.0.0.1:${PORT}/api/v2.0"
echo "==> auth_mode hiện tại"
curl -fsS -u "admin:${HARBOR_ADMIN_PASSWORD}" "${API}/configurations" | grep -o '"auth_mode":{[^}]*}' || true

echo "==> PUT /configurations (oidc_auth → ${ISSUER})"
curl -fsS -u "admin:${HARBOR_ADMIN_PASSWORD}" -X PUT "${API}/configurations" \
  -H 'Content-Type: application/json' -d @- <<EOF
{
  "auth_mode": "oidc_auth",
  "oidc_name": "Keycloak",
  "oidc_endpoint": "${ISSUER}",
  "oidc_client_id": "harbor",
  "oidc_client_secret": "${SECRET}",
  "oidc_scope": "openid,profile,email",
  "oidc_verify_cert": false,
  "oidc_auto_onboard": true,
  "oidc_user_claim": "preferred_username",
  "oidc_groups_claim": "groups",
  "oidc_admin_group": "${ADMIN_GROUP}"
}
EOF

echo "OK — https://npd-harbor.co → LOGIN VIA OIDC PROVIDER. Admin local: https://npd-harbor.co/account/sign-in"
