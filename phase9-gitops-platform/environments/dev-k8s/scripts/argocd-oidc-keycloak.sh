#!/usr/bin/env bash
# ArgoCD OIDC → Keycloak (realm platform, client argocd). Client secret đọc từ Vault.
# Lab: group platform-admin → role:admin, policy.default role:admin. Local admin vẫn dùng được.
#
#   export VAULT_TOKEN=...
#   bash phase9-gitops-platform/environments/dev-k8s/scripts/argocd-oidc-keycloak.sh
#
# ArgoCD cài bằng Helm tay: `helm upgrade` sau này sẽ ghi đè argocd-cm/argocd-rbac-cm → chạy lại script.
set -euo pipefail

: "${VAULT_TOKEN:?export VAULT_TOKEN}"
NS="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_URL="${ARGOCD_URL:-https://npd-argocd.co}"
ISSUER="${KEYCLOAK_ISSUER:-https://npd-keycloak.co/realms/platform}"
ADMIN_GROUP="${ADMIN_GROUP:-platform-admin}"

SECRET=$(kubectl exec -i -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN}" \
  vault kv get -field=argocd secret/platform/keycloak-clients)

echo "==> argocd-secret: oidc.keycloak.clientSecret"
kubectl -n "${NS}" patch secret argocd-secret --type merge \
  -p "{\"stringData\":{\"oidc.keycloak.clientSecret\":\"${SECRET}\"}}"

echo "==> argocd-cm: url + oidc.config"
cat <<EOF | kubectl -n "${NS}" patch configmap argocd-cm --type merge --patch-file /dev/stdin
data:
  url: ${ARGOCD_URL}
  oidc.tls.insecure.skip.verify: "true"
  oidc.config: |
    name: Keycloak
    issuer: ${ISSUER}
    clientID: argocd
    clientSecret: \$oidc.keycloak.clientSecret
    requestedScopes: ["openid", "profile", "email"]
    logoutURL: ${ISSUER}/protocol/openid-connect/logout?client_id=argocd&post_logout_redirect_uri={{logoutRedirectURL}}
EOF

echo "==> argocd-rbac-cm"
cat <<EOF | kubectl -n "${NS}" patch configmap argocd-rbac-cm --type merge --patch-file /dev/stdin
data:
  policy.default: role:admin
  scopes: "[groups, email]"
  policy.csv: |
    g, ${ADMIN_GROUP}, role:admin
EOF

kubectl -n "${NS}" rollout restart deployment/argocd-server
kubectl -n "${NS}" rollout status deployment/argocd-server --timeout=180s
echo "OK — ${ARGOCD_URL} → LOG IN VIA KEYCLOAK"
